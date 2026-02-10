package llm

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// DownloadStatus represents the current state of a download
type DownloadStatus struct {
	ModelID    string  `json:"modelId"`
	FileName   string  `json:"fileName"`
	TotalBytes int64   `json:"totalBytes"`
	DoneBytes  int64   `json:"doneBytes"`
	Percent    float64 `json:"percent"`
	Speed      string  `json:"speed"`
	Status     string  `json:"status"` // "downloading", "complete", "error", "cancelled"
	Error      string  `json:"error,omitempty"`
}

// LocalModel represents a model stored on disk
type LocalModel struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	FileName string `json:"fileName"`
	FilePath string `json:"filePath"`
	Size     int64  `json:"size"`
	SizeStr  string `json:"sizeStr"`
}

// ModelDownloader handles downloading and managing local GGUF model files
type ModelDownloader struct {
	modelsDir string
	mu        sync.RWMutex
	downloads map[string]*activeDownload
}

type activeDownload struct {
	cancel context.CancelFunc
	status DownloadStatus
}

// NewModelDownloader creates a new model downloader
func NewModelDownloader(modelsDir string) *ModelDownloader {
	os.MkdirAll(modelsDir, 0755)
	return &ModelDownloader{
		modelsDir: modelsDir,
		downloads: make(map[string]*activeDownload),
	}
}

// ModelsDir returns the models directory path
func (d *ModelDownloader) ModelsDir() string {
	return d.modelsDir
}

// ListLocalModels returns all locally downloaded GGUF models
func (d *ModelDownloader) ListLocalModels() ([]LocalModel, error) {
	entries, err := os.ReadDir(d.modelsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return []LocalModel{}, nil
		}
		return nil, err
	}

	var models []LocalModel
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(strings.ToLower(entry.Name()), ".gguf") {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			continue
		}

		filePath := filepath.Join(d.modelsDir, entry.Name())

		// Try to match to a known model
		id := fileNameToID(entry.Name())
		name := entry.Name()
		if known := FindModelByID(id); known != nil {
			name = known.Name
		}

		models = append(models, LocalModel{
			ID:       id,
			Name:     name,
			FileName: entry.Name(),
			FilePath: filePath,
			Size:     info.Size(),
			SizeStr:  formatBytes(info.Size()),
		})
	}

	return models, nil
}

// GetModelPath returns the file path for a model if it exists locally
func (d *ModelDownloader) GetModelPath(modelID string) (string, error) {
	// Check if a known model by ID
	if entry := FindModelByID(modelID); entry != nil {
		path := filepath.Join(d.modelsDir, entry.HFFile)
		if _, err := os.Stat(path); err == nil {
			return path, nil
		}
	}

	// Check if it's a direct filename
	path := filepath.Join(d.modelsDir, modelID)
	if _, err := os.Stat(path); err == nil {
		return path, nil
	}

	// Search for matching files
	models, err := d.ListLocalModels()
	if err != nil {
		return "", err
	}
	for _, m := range models {
		if m.ID == modelID {
			return m.FilePath, nil
		}
	}

	return "", fmt.Errorf("model %s not found locally", modelID)
}

// IsModelDownloaded checks if a model is available locally
func (d *ModelDownloader) IsModelDownloaded(modelID string) bool {
	_, err := d.GetModelPath(modelID)
	return err == nil
}

// DownloadModel downloads a model by its registry ID
func (d *ModelDownloader) DownloadModel(ctx context.Context, modelID string) error {
	entry := FindModelByID(modelID)
	if entry == nil {
		return fmt.Errorf("unknown model: %s", modelID)
	}

	return d.DownloadFromURL(ctx, modelID, entry.DownloadURL, entry.HFFile)
}

// DownloadFromURL downloads a GGUF file from a URL
func (d *ModelDownloader) DownloadFromURL(ctx context.Context, modelID, url, fileName string) error {
	d.mu.Lock()
	if _, exists := d.downloads[modelID]; exists {
		d.mu.Unlock()
		return fmt.Errorf("download already in progress for %s", modelID)
	}

	dlCtx, cancel := context.WithCancel(ctx)
	dl := &activeDownload{
		cancel: cancel,
		status: DownloadStatus{
			ModelID:  modelID,
			FileName: fileName,
			Status:   "downloading",
		},
	}
	d.downloads[modelID] = dl
	d.mu.Unlock()

	defer func() {
		d.mu.Lock()
		delete(d.downloads, modelID)
		d.mu.Unlock()
	}()

	destPath := filepath.Join(d.modelsDir, fileName)
	tmpPath := destPath + ".tmp"

	// Create HTTP request
	req, err := http.NewRequestWithContext(dlCtx, "GET", url, nil)
	if err != nil {
		dl.status.Status = "error"
		dl.status.Error = err.Error()
		return err
	}

	// Check for partial download to resume
	var startBytes int64
	if stat, err := os.Stat(tmpPath); err == nil {
		startBytes = stat.Size()
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", startBytes))
	}

	client := &http.Client{Timeout: 0} // no timeout for large downloads
	resp, err := client.Do(req)
	if err != nil {
		dl.status.Status = "error"
		dl.status.Error = err.Error()
		return fmt.Errorf("download request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusPartialContent {
		dl.status.Status = "error"
		dl.status.Error = fmt.Sprintf("HTTP %d", resp.StatusCode)
		return fmt.Errorf("download failed with status %d", resp.StatusCode)
	}

	totalSize := resp.ContentLength
	if resp.StatusCode == http.StatusPartialContent {
		totalSize += startBytes
	}
	dl.status.TotalBytes = totalSize

	// Open file for writing (append if resuming)
	flags := os.O_CREATE | os.O_WRONLY
	if startBytes > 0 && resp.StatusCode == http.StatusPartialContent {
		flags |= os.O_APPEND
	} else {
		flags |= os.O_TRUNC
		startBytes = 0
	}

	f, err := os.OpenFile(tmpPath, flags, 0644)
	if err != nil {
		dl.status.Status = "error"
		dl.status.Error = err.Error()
		return err
	}
	defer f.Close()

	// Download with progress tracking
	buf := make([]byte, 256*1024) // 256KB buffer
	downloaded := startBytes
	lastTime := time.Now()
	lastBytes := downloaded

	for {
		select {
		case <-dlCtx.Done():
			dl.status.Status = "cancelled"
			return fmt.Errorf("download cancelled")
		default:
		}

		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			if _, writeErr := f.Write(buf[:n]); writeErr != nil {
				dl.status.Status = "error"
				dl.status.Error = writeErr.Error()
				return writeErr
			}
			downloaded += int64(n)

			// Update progress
			dl.status.DoneBytes = downloaded
			if totalSize > 0 {
				dl.status.Percent = float64(downloaded) / float64(totalSize) * 100
			}

			// Calculate speed every second
			now := time.Now()
			elapsed := now.Sub(lastTime)
			if elapsed >= time.Second {
				bytesPerSec := float64(downloaded-lastBytes) / elapsed.Seconds()
				dl.status.Speed = formatBytes(int64(bytesPerSec)) + "/s"
				lastTime = now
				lastBytes = downloaded
			}
		}

		if readErr != nil {
			if readErr == io.EOF {
				break
			}
			dl.status.Status = "error"
			dl.status.Error = readErr.Error()
			return readErr
		}
	}

	f.Close()

	// Move tmp to final destination
	if err := os.Rename(tmpPath, destPath); err != nil {
		dl.status.Status = "error"
		dl.status.Error = err.Error()
		return err
	}

	dl.status.Status = "complete"
	dl.status.Percent = 100
	dl.status.DoneBytes = downloaded
	return nil
}

// CancelDownload cancels an active download
func (d *ModelDownloader) CancelDownload(modelID string) {
	d.mu.RLock()
	dl, exists := d.downloads[modelID]
	d.mu.RUnlock()
	if exists {
		dl.cancel()
	}
}

// GetDownloadStatus returns the status of an active download
func (d *ModelDownloader) GetDownloadStatus(modelID string) *DownloadStatus {
	d.mu.RLock()
	defer d.mu.RUnlock()
	if dl, exists := d.downloads[modelID]; exists {
		status := dl.status // copy
		return &status
	}
	return nil
}

// GetAllDownloadStatuses returns all active download statuses
func (d *ModelDownloader) GetAllDownloadStatuses() []DownloadStatus {
	d.mu.RLock()
	defer d.mu.RUnlock()
	var statuses []DownloadStatus
	for _, dl := range d.downloads {
		statuses = append(statuses, dl.status)
	}
	return statuses
}

// DeleteModel removes a downloaded model file
func (d *ModelDownloader) DeleteModel(modelID string) error {
	path, err := d.GetModelPath(modelID)
	if err != nil {
		return err
	}
	return os.Remove(path)
}

// fileNameToID creates an ID from a GGUF filename
func fileNameToID(filename string) string {
	// Try to match known models first
	for _, m := range AvailableModels() {
		if m.HFFile == filename {
			return m.ID
		}
	}
	// Fallback: use filename without extension
	name := strings.TrimSuffix(filename, filepath.Ext(filename))
	name = strings.ToLower(name)
	name = strings.ReplaceAll(name, " ", "-")
	return name
}

// formatBytes formats bytes into human-readable string
func formatBytes(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}
