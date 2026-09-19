package llm

import (
	"archive/tar"
	"bufio"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

// LocalServer manages a llama-server subprocess
type LocalServer struct {
	mu          sync.RWMutex
	binDir      string
	binPath     string
	cmd         *exec.Cmd
	cancelCmd   context.CancelFunc
	port        int
	modelPath   string
	running     bool
	ready       bool
	modelName   string
	exitErr     error
	stderrLines []string
}

// ServerStatus represents the current state of the local server
type ServerStatus struct {
	Running     bool   `json:"running"`
	Ready       bool   `json:"ready"`
	ModelName   string `json:"modelName"`
	ModelPath   string `json:"modelPath"`
	Port        int    `json:"port"`
	BinaryFound bool   `json:"binaryFound"`
	Error       string `json:"error"`
}

// NewLocalServer creates a new local server manager
func NewLocalServer(binDir string) *LocalServer {
	os.MkdirAll(binDir, 0755)
	return &LocalServer{
		binDir: binDir,
		port:   8372, // frog's local port
	}
}

// findBinary locates the llama-server binary
func (s *LocalServer) findBinary() string {
	// Check the cached path first
	if s.binPath != "" {
		if _, err := os.Stat(s.binPath); err == nil {
			return s.binPath
		}
	}

	// Check direct path in bin directory
	direct := filepath.Join(s.binDir, "llama-server")
	if _, err := os.Stat(direct); err == nil {
		return direct
	}

	// Search subdirectories (archive extracts into e.g. llama-b7972/)
	var found string
	filepath.Walk(s.binDir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if !info.IsDir() && info.Name() == "llama-server" {
			found = path
			return filepath.SkipAll
		}
		return nil
	})
	if found != "" {
		return found
	}

	// Also check PATH
	if pathBin, err := exec.LookPath("llama-server"); err == nil {
		return pathBin
	}

	return ""
}

// IsBinaryInstalled checks if llama-server is available
func (s *LocalServer) IsBinaryInstalled() bool {
	return s.findBinary() != ""
}

// GetBinaryPath returns the path to the llama-server binary
func (s *LocalServer) GetBinaryPath() string {
	return s.findBinary()
}

// assetNamePattern returns the substring to match in release asset names
func assetNamePattern() string {
	os_ := runtime.GOOS
	arch := runtime.GOARCH

	switch {
	case os_ == "darwin" && arch == "arm64":
		return "macos-arm64"
	case os_ == "darwin" && arch == "amd64":
		return "macos-x64"
	case os_ == "linux" && arch == "amd64":
		return "ubuntu-x64"
	default:
		return ""
	}
}

// resolveReleaseAssetURL queries the GitHub API for the actual download URL
func resolveReleaseAssetURL(ctx context.Context) (downloadURL string, format string, err error) {
	pattern := assetNamePattern()
	if pattern == "" {
		return "", "", fmt.Errorf("no pre-built binary available for %s/%s", runtime.GOOS, runtime.GOARCH)
	}

	apiURL := "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
	req, err := http.NewRequestWithContext(ctx, "GET", apiURL, nil)
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Accept", "application/vnd.github+json")

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("github API request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", "", err
	}

	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("github API returned %d", resp.StatusCode)
	}

	// Parse JSON to find matching asset
	type asset struct {
		Name               string `json:"name"`
		BrowserDownloadURL string `json:"browser_download_url"`
	}
	type release struct {
		Assets []asset `json:"assets"`
	}

	var rel release
	if err := json.Unmarshal(body, &rel); err != nil {
		return "", "", fmt.Errorf("parse release JSON: %w", err)
	}

	for _, a := range rel.Assets {
		nameLower := strings.ToLower(a.Name)
		if strings.Contains(nameLower, pattern) && strings.Contains(nameLower, "bin") {
			if strings.HasSuffix(nameLower, ".tar.gz") {
				return a.BrowserDownloadURL, "tar.gz", nil
			}
			if strings.HasSuffix(nameLower, ".zip") {
				return a.BrowserDownloadURL, "zip", nil
			}
		}
	}

	return "", "", fmt.Errorf("no matching release asset found for pattern %q", pattern)
}

// InstallBinary downloads and installs the llama-server binary
func (s *LocalServer) InstallBinary(ctx context.Context) error {
	url, format, err := resolveReleaseAssetURL(ctx)
	if err != nil {
		return fmt.Errorf("resolve download URL: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}

	client := &http.Client{Timeout: 10 * time.Minute}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("download failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download failed with status %d", resp.StatusCode)
	}

	// Save to temp file
	tmpFile, err := os.CreateTemp(s.binDir, "llama-download-*")
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}
	tmpPath := tmpFile.Name()
	defer os.Remove(tmpPath)

	if _, err := io.Copy(tmpFile, resp.Body); err != nil {
		tmpFile.Close()
		return fmt.Errorf("download write: %w", err)
	}
	tmpFile.Close()

	// Extract based on format
	switch format {
	case "zip":
		if err := extractZip(tmpPath, s.binDir); err != nil {
			return fmt.Errorf("extract: %w", err)
		}
	case "tar.gz":
		if err := extractTarGz(tmpPath, s.binDir); err != nil {
			return fmt.Errorf("extract: %w", err)
		}
	}

	// Find the llama-server binary after extraction
	var binPath string
	filepath.Walk(s.binDir, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return nil
		}
		if !info.IsDir() && info.Name() == "llama-server" {
			binPath = path
			return filepath.SkipAll
		}
		return nil
	})

	if binPath == "" {
		return fmt.Errorf("llama-server binary not found after extraction")
	}

	os.Chmod(binPath, 0755)
	s.binPath = binPath

	// Create short-name symlinks for dylibs (e.g. libmtmd.0.dylib -> libmtmd.0.0.7972.dylib)
	createDylibSymlinks(filepath.Dir(binPath))

	return nil
}

// createDylibSymlinks creates short-name symlinks for versioned .dylib files.
// llama-server expects e.g. @rpath/libmtmd.0.dylib but the archive contains
// libmtmd.0.0.7972.dylib with no symlink. This bridges the gap.
func createDylibSymlinks(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".dylib") || e.Type()&os.ModeSymlink != 0 {
			continue
		}
		// Match patterns like libFoo.X.Y.Z.dylib -> create libFoo.X.dylib
		// e.g. "libmtmd.0.0.7972.dylib" -> "libmtmd.0.dylib"
		// e.g. "libggml-base.0.9.5.dylib" -> "libggml-base.0.dylib"
		base := strings.TrimSuffix(name, ".dylib")
		parts := strings.SplitN(base, ".", 3) // ["libmtmd", "0", "0.7972"] or ["libggml-base", "0", "9.5"]
		if len(parts) < 3 {
			continue // already a short name like libfoo.0.dylib
		}
		shortName := parts[0] + "." + parts[1] + ".dylib"
		shortPath := filepath.Join(dir, shortName)
		if _, err := os.Lstat(shortPath); err == nil {
			continue // symlink already exists
		}
		os.Symlink(name, shortPath)
	}
}

// Start launches the llama-server with the specified model
func (s *LocalServer) Start(modelPath string, modelName string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.running {
		// If same model, no-op
		if s.modelPath == modelPath {
			return nil
		}
		// Different model, stop first
		s.stopLocked()
	}

	binPath := s.findBinary()
	if binPath == "" {
		return fmt.Errorf("llama-server binary not found. Please install it first.")
	}

	// Ensure short-name dylib symlinks exist (in case binary was installed before this fix)
	createDylibSymlinks(filepath.Dir(binPath))

	// Find a free port
	port, err := freePort()
	if err != nil {
		port = s.port
	}
	s.port = port

	args := []string{
		"-m", modelPath,
		"--port", fmt.Sprintf("%d", s.port),
		"--host", "127.0.0.1",
		"-c", "4096",
		"-ngl", "99", // offload all layers to GPU (Metal on macOS)
	}

	// Use a standalone context so the subprocess is not tied to the Wails app context
	cmdCtx, cancelCmd := context.WithCancel(context.Background())
	s.cancelCmd = cancelCmd

	s.cmd = exec.CommandContext(cmdCtx, binPath, args...)
	s.cmd.Stdout = io.Discard

	// Capture stderr for diagnostics
	stderrPipe, err := s.cmd.StderrPipe()
	if err != nil {
		cancelCmd()
		return fmt.Errorf("failed to create stderr pipe: %w", err)
	}

	if err := s.cmd.Start(); err != nil {
		cancelCmd()
		return fmt.Errorf("failed to start llama-server: %w", err)
	}

	s.modelPath = modelPath
	s.modelName = modelName
	s.running = true
	s.ready = false
	s.exitErr = nil
	s.stderrLines = nil

	// Goroutine: capture stderr line by line
	go func() {
		scanner := bufio.NewScanner(stderrPipe)
		for scanner.Scan() {
			line := scanner.Text()
			log.Printf("[llama-server] %s", line)
			s.mu.Lock()
			s.stderrLines = append(s.stderrLines, line)
			if len(s.stderrLines) > 100 {
				s.stderrLines = s.stderrLines[len(s.stderrLines)-100:]
			}
			s.mu.Unlock()
		}
	}()

	// Goroutine: detect process exit
	go func() {
		err := s.cmd.Wait()
		s.mu.Lock()
		s.running = false
		s.ready = false
		s.exitErr = err
		s.mu.Unlock()
	}()

	// Wait for server to be ready (in background, caller can check status)
	go s.waitForReady()

	return nil
}

// waitForReady polls the health endpoint until the server is responding
func (s *LocalServer) waitForReady() {
	client := &http.Client{Timeout: 2 * time.Second}
	endpoint := fmt.Sprintf("http://127.0.0.1:%d/health", s.port)

	for i := 0; i < 120; i++ { // wait up to 2 minutes
		time.Sleep(time.Second)

		s.mu.RLock()
		running := s.running
		s.mu.RUnlock()

		if !running {
			log.Printf("[llama-server] process exited before becoming ready")
			return
		}

		resp, err := client.Get(endpoint)
		if err != nil {
			continue
		}
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			s.mu.Lock()
			s.ready = true
			s.mu.Unlock()
			log.Printf("[llama-server] server is ready on port %d", s.port)
			return
		}
	}

	log.Printf("[llama-server] timed out waiting for server to become ready")
}

// Stop terminates the llama-server process
func (s *LocalServer) Stop() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stopLocked()
}

func (s *LocalServer) stopLocked() {
	if !s.running || s.cmd == nil || s.cmd.Process == nil {
		s.running = false
		s.ready = false
		return
	}

	// Try graceful shutdown first
	s.cmd.Process.Signal(os.Interrupt)

	done := make(chan struct{}, 1)
	go func() {
		s.cmd.Process.Wait()
		done <- struct{}{}
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		s.cmd.Process.Kill()
	}

	// Cancel the command context
	if s.cancelCmd != nil {
		s.cancelCmd()
		s.cancelCmd = nil
	}

	s.running = false
	s.ready = false
	s.exitErr = nil
	s.stderrLines = nil
	s.cmd = nil
}

// IsRunning checks if the server process is alive and responding
func (s *LocalServer) IsRunning() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.running
}

// IsReady checks if the server is ready to accept requests
func (s *LocalServer) IsReady() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.running && s.ready
}

// GetStatus returns the current server status
func (s *LocalServer) GetStatus() ServerStatus {
	s.mu.RLock()
	defer s.mu.RUnlock()
	status := ServerStatus{
		Running:     s.running,
		Ready:       s.ready,
		ModelName:   s.modelName,
		ModelPath:   s.modelPath,
		Port:        s.port,
		BinaryFound: s.findBinary() != "",
	}
	if s.exitErr != nil {
		status.Error = s.exitErr.Error()
	}
	return status
}

// GetLogs returns the captured stderr lines from llama-server
func (s *LocalServer) GetLogs() []string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	lines := make([]string, len(s.stderrLines))
	copy(lines, s.stderrLines)
	return lines
}

// Endpoint returns the OpenAI-compatible API endpoint
func (s *LocalServer) Endpoint() string {
	return fmt.Sprintf("http://127.0.0.1:%d/v1", s.port)
}

// NewProvider creates an OpenAI-compatible provider pointing at the local server
func (s *LocalServer) NewProvider() Provider {
	return NewOpenAIProvider("Local", s.Endpoint(), "no-key-needed", "local")
}

// freePort finds an available TCP port
func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

// extractZip extracts a zip file to a directory
func extractZip(zipPath, destDir string) error {
	// Use unzip command (available on macOS and most Linux)
	cmd := exec.Command("unzip", "-o", zipPath, "-d", destDir)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	return cmd.Run()
}

// extractTarGz extracts a tar.gz file to a directory
func extractTarGz(tarPath, destDir string) error {
	f, err := os.Open(tarPath)
	if err != nil {
		return err
	}
	defer f.Close()

	gzr, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	defer gzr.Close()

	tr := tar.NewReader(gzr)
	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}

		target := filepath.Join(destDir, header.Name)

		// Prevent path traversal
		if !strings.HasPrefix(filepath.Clean(target), filepath.Clean(destDir)) {
			continue
		}

		switch header.Typeflag {
		case tar.TypeDir:
			os.MkdirAll(target, 0755)
		case tar.TypeReg:
			os.MkdirAll(filepath.Dir(target), 0755)
			outFile, err := os.Create(target)
			if err != nil {
				return err
			}
			if _, err := io.Copy(outFile, tr); err != nil {
				outFile.Close()
				return err
			}
			outFile.Close()
			os.Chmod(target, os.FileMode(header.Mode))
		}
	}
	return nil
}
