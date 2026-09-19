<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { showNotification } from '../stores/app';
  import {
    GetAvailableModels,
    GetLocalModels,
    DownloadModel,
    DeleteLocalModel,
    SetActiveModel,
    GetServerStatus,
    IsServerReady,
    IsBinaryInstalled,
    InstallBinary,
    StopLocalServer,
    GetDownloadStatus,
    GetAllDownloadStatuses,
    CancelDownload,
    GetLLMConfig,
    GetServerLogs,
    GetServerError,
  } from '../../wailsjs/go/main/App';

  interface ModelEntry {
    id: string;
    name: string;
    description: string;
    size: string;
    parameters: string;
  }

  interface LocalModel {
    id: string;
    name: string;
    fileName: string;
    filePath: string;
    size: number;
    sizeStr: string;
  }

  interface ServerStatus {
    running: boolean;
    modelName: string;
    modelPath: string;
    port: number;
    binaryFound: boolean;
  }

  interface DownloadStatusInfo {
    modelId: string;
    fileName: string;
    totalBytes: number;
    doneBytes: number;
    percent: number;
    speed: string;
    status: string;
    error?: string;
  }

  let availableModels: ModelEntry[] = [];
  let localModels: LocalModel[] = [];
  let serverStatus: ServerStatus = { running: false, modelName: '', modelPath: '', port: 0, binaryFound: false };
  let serverReady = false;
  let serverError = '';
  let activeModelId = '';
  let loading = true;
  let installingBinary = false;

  // Download tracking
  let activeDownloads: Record<string, DownloadStatusInfo> = {};
  let downloadingModels: Set<string> = new Set();
  let pollInterval: ReturnType<typeof setInterval>;

  onMount(async () => {
    await refresh();
    // Poll for download progress and server status
    pollInterval = setInterval(pollStatus, 1500);
  });

  onDestroy(() => {
    if (pollInterval) clearInterval(pollInterval);
  });

  async function refresh() {
    loading = true;
    try {
      availableModels = await GetAvailableModels() || [];
      localModels = await GetLocalModels() || [];
      serverStatus = await GetServerStatus();
      serverReady = await IsServerReady();
      serverError = '';
      const cfg = await GetLLMConfig();
      activeModelId = cfg?.local?.modelId || '';
    } catch (err: any) {
      showNotification(err?.message || 'Failed to load model info', 'error');
    }
    loading = false;
  }

  async function pollStatus() {
    try {
      // Poll server status
      serverStatus = await GetServerStatus();
      serverReady = await IsServerReady();

      // Check if server crashed
      if (serverStatus.running === false && activeModelId) {
        serverError = await GetServerError();
      } else {
        serverError = '';
      }

      // Poll download progress
      const statuses: DownloadStatusInfo[] = await GetAllDownloadStatuses() || [];
      const newDownloads: Record<string, DownloadStatusInfo> = {};
      const stillDownloading = new Set<string>();

      for (const s of statuses) {
        newDownloads[s.modelId] = s;
        if (s.status === 'downloading') {
          stillDownloading.add(s.modelId);
        }
      }

      // Check if any downloads just completed
      for (const modelId of downloadingModels) {
        if (!stillDownloading.has(modelId)) {
          // Download finished, refresh model list
          localModels = await GetLocalModels() || [];
        }
      }

      activeDownloads = newDownloads;
      downloadingModels = stillDownloading;
    } catch {
      // Ignore polling errors
    }
  }

  async function downloadModel(modelId: string) {
    downloadingModels.add(modelId);
    downloadingModels = downloadingModels; // trigger reactivity
    showNotification('Download started...', 'info');

    try {
      await DownloadModel(modelId);
      showNotification('Model downloaded successfully', 'success');
      await refresh();
    } catch (err: any) {
      showNotification(err?.message || 'Download failed', 'error');
    } finally {
      downloadingModels.delete(modelId);
      downloadingModels = downloadingModels;
    }
  }

  async function cancelDl(modelId: string) {
    try {
      await CancelDownload(modelId);
      showNotification('Download cancelled', 'info');
    } catch {
      // ignore
    }
  }

  async function deleteModel(modelId: string) {
    try {
      await DeleteLocalModel(modelId);
      showNotification('Model deleted', 'success');
      await refresh();
    } catch (err: any) {
      showNotification(err?.message || 'Failed to delete', 'error');
    }
  }

  async function activateModel(modelId: string) {
    showNotification('Loading model...', 'info');
    try {
      await SetActiveModel(modelId);
      activeModelId = modelId;
      showNotification('Model activated. Server starting...', 'success');
    } catch (err: any) {
      showNotification(err?.message || 'Failed to activate model', 'error');
    }
  }

  async function stopServer() {
    try {
      await StopLocalServer();
      showNotification('Server stopped', 'info');
      serverStatus = await GetServerStatus();
      serverReady = false;
    } catch (err: any) {
      showNotification(err?.message || 'Failed to stop server', 'error');
    }
  }

  async function installEngine() {
    installingBinary = true;
    showNotification('Downloading inference engine... This may take a minute.', 'info');
    try {
      await InstallBinary();
      showNotification('Inference engine installed', 'success');
      serverStatus = await GetServerStatus();
    } catch (err: any) {
      showNotification(err?.message || 'Failed to install engine', 'error');
    }
    installingBinary = false;
  }

  function isDownloaded(modelId: string): boolean {
    return localModels.some(m => m.id === modelId);
  }

  function isDownloading(modelId: string): boolean {
    return downloadingModels.has(modelId) || (activeDownloads[modelId]?.status === 'downloading');
  }

  function getProgress(modelId: string): DownloadStatusInfo | null {
    return activeDownloads[modelId] || null;
  }

  function formatBytes(b: number): string {
    if (b === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(b) / Math.log(k));
    return parseFloat((b / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
  }
</script>

<div class="model-manager">
  <div class="mm-header">
    <h2>Models</h2>
    <button class="refresh-btn" on:click={refresh} disabled={loading}>
      {loading ? 'Loading...' : 'Refresh'}
    </button>
  </div>

  <!-- Engine status -->
  {#if !serverStatus.binaryFound}
    <div class="engine-banner">
      <div class="banner-text">
        <strong>Inference engine not found</strong>
        <span>Frog needs llama-server to run local models. Click below to install it automatically.</span>
      </div>
      <button class="primary-btn" on:click={installEngine} disabled={installingBinary}>
        {installingBinary ? 'Installing...' : 'Install Engine'}
      </button>
    </div>
  {/if}

  <!-- Server status -->
  <div class="status-bar" class:online={serverReady} class:starting={serverStatus.running && !serverReady} class:offline={!serverStatus.running && !serverError} class:error={!!serverError}>
    <span class="status-dot"></span>
    {#if serverReady}
      <span>Running: <strong>{serverStatus.modelName}</strong></span>
      <button class="small-btn stop" on:click={stopServer}>Stop</button>
    {:else if serverStatus.running}
      <span>Starting up... loading model</span>
    {:else if serverError}
      <span>Server crashed: <strong>{serverError}</strong></span>
    {:else}
      <span>Server idle &mdash; select a model below to start</span>
    {/if}
  </div>

  <!-- Available models to download -->
  <div class="section">
    <h3>Available Models</h3>
    <div class="model-grid">
      {#each availableModels as model}
        {@const downloaded = isDownloaded(model.id)}
        {@const downloading = isDownloading(model.id)}
        {@const progress = getProgress(model.id)}
        <div class="model-card" class:downloaded class:active={model.id === activeModelId}>
          <div class="model-card-header">
            <span class="model-name">{model.name}</span>
            <span class="model-params">{model.parameters}</span>
          </div>
          <p class="model-desc">{model.description}</p>
          <div class="model-card-footer">
            <span class="model-size">{model.size}</span>
            <div class="model-card-actions">
              {#if downloading && progress}
                <div class="download-progress">
                  <div class="progress-bar">
                    <div class="progress-fill" style="width: {progress.percent}%"></div>
                  </div>
                  <span class="progress-text">{progress.percent.toFixed(0)}% {progress.speed || ''}</span>
                  <button class="small-btn danger" on:click={() => cancelDl(model.id)}>Cancel</button>
                </div>
              {:else if downloading}
                <span class="downloading-text">Downloading...</span>
              {:else if downloaded}
                {#if model.id === activeModelId}
                  <span class="active-badge">Active</span>
                {:else}
                  <button class="small-btn accent" on:click={() => activateModel(model.id)}>Use</button>
                {/if}
                <button class="small-btn danger" on:click={() => deleteModel(model.id)}>Delete</button>
              {:else}
                <button class="primary-btn small" on:click={() => downloadModel(model.id)}
                  disabled={!serverStatus.binaryFound && false}>
                  Download
                </button>
              {/if}
            </div>
          </div>
        </div>
      {/each}
    </div>
  </div>

  <!-- Locally downloaded models (including custom ones not in registry) -->
  {#if localModels.some(m => !availableModels.find(a => a.id === m.id))}
    <div class="section">
      <h3>Custom Models</h3>
      <div class="models-list">
        {#each localModels.filter(m => !availableModels.find(a => a.id === m.id)) as model}
          <div class="model-item" class:active={model.id === activeModelId}>
            <div class="model-info">
              <span class="model-name">{model.fileName}</span>
              <span class="model-meta">
                {model.sizeStr}
                {#if model.id === activeModelId}
                  <span class="active-badge">Active</span>
                {/if}
              </span>
            </div>
            <div class="model-actions">
              {#if model.id !== activeModelId}
                <button class="small-btn accent" on:click={() => activateModel(model.id)}>Use</button>
              {/if}
              <button class="small-btn danger" on:click={() => deleteModel(model.id)}>Delete</button>
            </div>
          </div>
        {/each}
      </div>
    </div>
  {/if}
</div>

<style>
  .model-manager {
    display: flex;
    flex-direction: column;
    height: 100%;
    padding: 0 20px 20px;
    gap: 16px;
    overflow-y: auto;
  }

  .mm-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .mm-header h2 {
    font-size: 16px;
    font-weight: 600;
  }

  .refresh-btn {
    padding: 6px 12px;
    font-size: 12px;
    border-radius: var(--radius-sm);
    background: var(--bg-tertiary);
    color: var(--text-secondary);
    transition: all var(--transition);
  }

  .refresh-btn:hover:not(:disabled) {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .engine-banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 14px 16px;
    border-radius: var(--radius-md);
    background: rgba(245, 158, 11, 0.1);
    border: 1px solid rgba(245, 158, 11, 0.3);
  }

  .banner-text {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .banner-text strong {
    font-size: 13px;
    color: var(--warning);
  }

  .banner-text span {
    font-size: 12px;
    color: var(--text-muted);
  }

  .status-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 14px;
    border-radius: var(--radius-md);
    font-size: 13px;
    font-weight: 500;
  }

  .status-bar.online {
    background: rgba(34, 197, 94, 0.1);
    color: var(--accent);
  }

  .status-bar.starting {
    background: rgba(59, 130, 246, 0.1);
    color: var(--info);
  }

  .status-bar.offline {
    background: var(--bg-secondary);
    color: var(--text-muted);
  }

  .status-bar.error {
    background: rgba(239, 68, 68, 0.1);
    color: var(--danger);
  }

  .status-bar.error .status-dot { background: var(--danger); }

  .status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .status-bar.online .status-dot { background: var(--accent); }
  .status-bar.starting .status-dot { background: var(--info); animation: pulse 1.5s infinite; }
  .status-bar.offline .status-dot { background: var(--text-muted); }

  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.3; }
  }

  .status-bar .stop {
    margin-left: auto;
  }

  .section {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .section h3 {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-secondary);
  }

  .model-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
    gap: 10px;
  }

  .model-card {
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-md);
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    transition: all var(--transition);
  }

  .model-card:hover {
    border-color: var(--text-muted);
  }

  .model-card.active {
    border-color: var(--accent);
    background: var(--accent-muted);
  }

  .model-card.downloaded {
    border-color: rgba(34, 197, 94, 0.3);
  }

  .model-card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .model-name {
    font-size: 13px;
    font-weight: 600;
  }

  .model-params {
    font-size: 10px;
    padding: 2px 6px;
    background: var(--bg-tertiary);
    border-radius: 3px;
    color: var(--text-muted);
    font-weight: 600;
  }

  .model-desc {
    font-size: 12px;
    color: var(--text-muted);
    line-height: 1.4;
  }

  .model-card-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-top: auto;
    padding-top: 8px;
    border-top: 1px solid var(--border-color);
  }

  .model-size {
    font-size: 11px;
    color: var(--text-muted);
    font-weight: 500;
  }

  .model-card-actions {
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .download-progress {
    display: flex;
    align-items: center;
    gap: 6px;
    width: 100%;
  }

  .progress-bar {
    flex: 1;
    height: 4px;
    background: var(--bg-tertiary);
    border-radius: 2px;
    overflow: hidden;
    min-width: 60px;
  }

  .progress-fill {
    height: 100%;
    background: var(--accent);
    border-radius: 2px;
    transition: width 0.3s ease;
  }

  .progress-text {
    font-size: 10px;
    color: var(--text-muted);
    white-space: nowrap;
  }

  .downloading-text {
    font-size: 11px;
    color: var(--info);
    font-weight: 500;
  }

  .primary-btn {
    padding: 7px 14px;
    background: var(--accent);
    color: #fff;
    font-weight: 600;
    font-size: 12px;
    border-radius: var(--radius-sm);
    transition: all var(--transition);
    white-space: nowrap;
  }

  .primary-btn.small {
    padding: 4px 10px;
    font-size: 11px;
  }

  .primary-btn:hover:not(:disabled) {
    background: var(--accent-hover);
  }

  .primary-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .active-badge {
    background: var(--accent);
    color: #fff;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 10px;
    font-weight: 600;
  }

  .small-btn {
    padding: 4px 10px;
    font-size: 11px;
    border-radius: 4px;
    background: var(--bg-tertiary);
    color: var(--text-secondary);
    transition: all var(--transition);
  }

  .small-btn:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .small-btn.accent:hover {
    background: var(--accent-muted);
    color: var(--accent);
  }

  .small-btn.danger:hover {
    background: rgba(239, 68, 68, 0.15);
    color: var(--danger);
  }

  .small-btn.stop {
    background: var(--bg-tertiary);
  }

  .small-btn.stop:hover {
    background: rgba(239, 68, 68, 0.15);
    color: var(--danger);
  }

  /* Custom models list (non-registry) */
  .models-list {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .model-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 14px;
    border-radius: var(--radius-sm);
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
  }

  .model-item.active {
    border-color: var(--accent);
    background: var(--accent-muted);
  }

  .model-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .model-meta {
    font-size: 11px;
    color: var(--text-muted);
    display: flex;
    align-items: center;
    gap: 6px;
  }

  .model-actions {
    display: flex;
    gap: 6px;
  }
</style>
