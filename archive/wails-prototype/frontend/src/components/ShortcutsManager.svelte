<script lang="ts">
  import { onMount } from 'svelte';
  import { showNotification } from '../stores/app';
  import {
    GetShortcuts,
    SaveShortcuts,
    ListInstalledApps,
    OpenApplication,
    GetGlobalHotkeys,
    SaveGlobalHotkeys,
    GetActions
  } from '../../wailsjs/go/main/App';
  import type { config, shortcuts } from '../../wailsjs/go/models';

  // State
  let appShortcuts: config.ShortcutConfig[] = [];
  let globalHotkeys: config.GlobalHotkeyConfig[] = [];
  let installedApps: shortcuts.AppInfo[] = [];
  let actions: config.ActionConfig[] = [];

  // UI State
  let activeTab: 'text' | 'apps' | 'system' = 'text';
  let showAddAppForm = false;
  let loadingApps = false;
  let recordingId: string | null = null; // ID of the item currently recording a hotkey

  // New App Shortcut Form
  let newName = '';
  let newHotkey = '';
  let newAppPath = '';
  let newBundleId = '';
  let newDescription = '';
  let selectedAppIndex = -1;

  onMount(async () => {
    await loadData();
  });

  async function loadData() {
    try {
      const [s, g, a] = await Promise.all([
        GetShortcuts(),
        GetGlobalHotkeys(),
        GetActions()
      ]);
      appShortcuts = s || [];
      globalHotkeys = g || [];
      actions = a || [];
    } catch (err) {
      console.error(err);
      showNotification('Failed to load shortcuts', 'error');
    }
  }

  // --- Global Hotkey Management (Text & System) ---

  function getGlobalHotkey(id: string): config.GlobalHotkeyConfig | undefined {
    return globalHotkeys.find(h => h.id === id);
  }

  function getActionName(actionID: string): string {
    const action = actions.find(a => a.id === actionID);
    return action ? action.name : actionID;
  }

  async function updateGlobalHotkey(id: string, hotkey: string) {
    const index = globalHotkeys.findIndex(h => h.id === id);
    if (index === -1) return;

    // Create a copy to trigger reactivity
    const updated = [...globalHotkeys];
    updated[index].hotkey = hotkey;
    globalHotkeys = updated;

    try {
      await SaveGlobalHotkeys(globalHotkeys);
      showNotification('Hotkey updated', 'success');
    } catch (err) {
      showNotification('Failed to save hotkey', 'error');
      // Revert on failure
      await loadData();
    }
    recordingId = null;
  }

  // --- App Shortcut Management ---

  async function loadApps() {
    if (installedApps.length > 0) return;
    loadingApps = true;
    try {
      installedApps = await ListInstalledApps() || [];
      installedApps.sort((a, b) => a.name.localeCompare(b.name));
    } catch (err) {
      showNotification('Failed to load apps', 'error');
    }
    loadingApps = false;
  }

  function onAppSelect() {
    if (selectedAppIndex >= 0 && selectedAppIndex < installedApps.length) {
      const app = installedApps[selectedAppIndex];
      newAppPath = app.path;
      newBundleId = app.bundleId;
      if (!newName) newName = app.name;
    }
  }

  async function addAppShortcut() {
    if (!newName.trim() || !newHotkey.trim() || (!newAppPath.trim() && !newBundleId.trim())) {
      showNotification('Please fill in name, hotkey, and select an app', 'error');
      return;
    }

    const shortcut = {
      id: `shortcut-${Date.now()}`,
      name: newName.trim(),
      hotkey: newHotkey.trim(),
      appPath: newAppPath.trim(),
      bundleId: newBundleId.trim(),
      description: newDescription.trim(),
    };

    const updated = [...appShortcuts, shortcut];
    
    try {
      await SaveShortcuts(updated as any); // Cast to any to avoid strict type checking issues with generated types
      appShortcuts = updated as any;
      showNotification('Shortcut added', 'success');
      resetAppForm();
    } catch (err) {
      showNotification('Failed to save shortcut', 'error');
    }
  }

  async function removeAppShortcut(id: string) {
    const updated = appShortcuts.filter(s => s.id !== id);
    try {
      await SaveShortcuts(updated);
      appShortcuts = updated;
      showNotification('Shortcut removed', 'success');
    } catch (err) {
      showNotification('Failed to save', 'error');
    }
  }

  async function executeAppShortcut(s: config.ShortcutConfig) {
    try {
      await OpenApplication(s.appPath, s.bundleId);
      showNotification(`Opened ${s.name}`, 'success');
    } catch (err: any) {
      showNotification(err?.message || `Failed to open ${s.name}`, 'error');
    }
  }

  // --- Hotkey Recording ---

  function startRecording(id: string) {
    recordingId = id;
    if (id === 'new') {
      newHotkey = 'Press keys...';
    }
  }

  function onKeyDown(e: KeyboardEvent) {
    if (!recordingId) return;
    
    e.preventDefault();
    e.stopPropagation();

    const parts: string[] = [];
    if (e.ctrlKey) parts.push('Ctrl');
    if (e.altKey) parts.push('Alt');
    if (e.shiftKey) parts.push('Shift');
    if (e.metaKey) parts.push('Cmd');

    const key = e.key;
    if (!['Control', 'Alt', 'Shift', 'Meta'].includes(key)) {
      parts.push(key.length === 1 ? key.toUpperCase() : key);
      const hotkeyStr = parts.join('+');
      
      if (recordingId === 'new') {
        newHotkey = hotkeyStr;
        recordingId = null;
      } else {
        updateGlobalHotkey(recordingId, hotkeyStr);
      }
    }
  }

  function resetAppForm() {
    showAddAppForm = false;
    newName = '';
    newHotkey = '';
    newAppPath = '';
    newBundleId = '';
    newDescription = '';
    selectedAppIndex = -1;
    recordingId = null;
  }
</script>

<svelte:window on:keydown={onKeyDown} />

<div class="shortcuts-manager">
  <div class="sm-header">
    <h2>Shortcuts</h2>
    <div class="tabs">
      <button class="tab-btn" class:active={activeTab === 'text'} on:click={() => activeTab = 'text'}>Text Actions</button>
      <button class="tab-btn" class:active={activeTab === 'system'} on:click={() => activeTab = 'system'}>System</button>
      <button class="tab-btn" class:active={activeTab === 'apps'} on:click={() => activeTab = 'apps'}>Apps</button>
    </div>
  </div>

  <div class="content-area">
    <!-- Text Actions Tab -->
    {#if activeTab === 'text'}
      <div class="hotkey-list">
        <p class="section-desc">Global hotkeys available anywhere in macOS.</p>
        {#each globalHotkeys.filter(h => h.category === 'text') as item}
          <div class="hotkey-item">
            <div class="hotkey-info">
              <span class="hotkey-name">{getActionName(item.action)}</span>
              <span class="hotkey-id">{item.action}</span>
            </div>
            <button 
              class="hotkey-badge" 
              class:recording={recordingId === item.id}
              on:click={() => startRecording(item.id)}
            >
              {recordingId === item.id ? 'Recording...' : item.hotkey || 'Set Hotkey'}
            </button>
          </div>
        {/each}
      </div>
    {/if}

    <!-- System Tab -->
    {#if activeTab === 'system'}
      <div class="hotkey-list">
        <p class="section-desc">Global system shortcuts.</p>
        {#each globalHotkeys.filter(h => h.category === 'system') as item}
          <div class="hotkey-item">
            <div class="hotkey-info">
              <span class="hotkey-name">{item.action === 'show' ? 'Show/Hide Frog' : item.action}</span>
            </div>
            <button 
              class="hotkey-badge" 
              class:recording={recordingId === item.id}
              on:click={() => startRecording(item.id)}
            >
              {recordingId === item.id ? 'Recording...' : item.hotkey || 'Set Hotkey'}
            </button>
          </div>
        {/each}
      </div>
    {/if}

    <!-- App Shortcuts Tab -->
    {#if activeTab === 'apps'}
      <div class="app-shortcuts">
        <div class="apps-header">
          <p class="section-desc">Launch apps with global hotkeys.</p>
          <button
            class="primary-btn"
            on:click={() => { showAddAppForm = !showAddAppForm; if (showAddAppForm) loadApps(); }}
          >
            {showAddAppForm ? 'Cancel' : 'Add Shortcut'}
          </button>
        </div>

        {#if showAddAppForm}
          <div class="add-form">
            <div class="form-row">
              <label>
                <span class="form-label">Application</span>
                {#if loadingApps}
                  <span class="loading-text">Loading apps...</span>
                {:else}
                  <select bind:value={selectedAppIndex} on:change={onAppSelect}>
                    <option value={-1}>Select an application...</option>
                    {#each installedApps as app, i}
                      <option value={i}>{app.name}</option>
                    {/each}
                  </select>
                {/if}
              </label>
            </div>
            
            <div class="form-row">
              <label>
                <span class="form-label">Name</span>
                <input type="text" bind:value={newName} placeholder="e.g. Browser" />
              </label>
            </div>

            <div class="form-row">
              <label>
                <span class="form-label">Hotkey</span>
                <button 
                  class="hotkey-input-btn"
                  class:recording={recordingId === 'new'}
                  on:click={() => startRecording('new')}
                >
                  {recordingId === 'new' ? 'Press keys...' : newHotkey || 'Click to record'}
                </button>
              </label>
            </div>

            <div class="form-row">
              <label>
                <span class="form-label">Description (optional)</span>
                <input type="text" bind:value={newDescription} placeholder="What this shortcut does" />
              </label>
            </div>

            <div class="form-actions">
              <button class="primary-btn" on:click={addAppShortcut}>Save Shortcut</button>
            </div>
          </div>
        {/if}

        <div class="shortcuts-list">
          {#if appShortcuts.length === 0}
            <div class="empty-state">No app shortcuts configured.</div>
          {:else}
            {#each appShortcuts as s}
              <div class="shortcut-item">
                <div class="shortcut-info">
                  <div class="shortcut-name">{s.name}</div>
                  {#if s.description}<div class="shortcut-desc">{s.description}</div>{/if}
                </div>
                <div class="shortcut-right">
                  <span class="static-badge">{s.hotkey}</span>
                  <div class="item-actions">
                    <button class="icon-btn" on:click={() => executeAppShortcut(s)} title="Launch">🚀</button>
                    <button class="icon-btn danger" on:click={() => removeAppShortcut(s.id)} title="Remove">🗑️</button>
                  </div>
                </div>
              </div>
            {/each}
          {/if}
        </div>
      </div>
    {/if}
  </div>
</div>

<style>
  .shortcuts-manager {
    display: flex;
    flex-direction: column;
    height: 100%;
    padding: 0 20px 20px;
    gap: 16px;
    overflow: hidden;
  }

  .sm-header {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .sm-header h2 {
    font-size: 16px;
    font-weight: 600;
  }

  .tabs {
    display: flex;
    gap: 4px;
    background: var(--bg-secondary);
    padding: 3px;
    border-radius: var(--radius-md);
    width: fit-content;
  }

  .tab-btn {
    padding: 6px 12px;
    font-size: 12px;
    font-weight: 500;
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    transition: all var(--transition);
  }

  .tab-btn:hover {
    color: var(--text-primary);
    background: var(--bg-hover);
  }

  .tab-btn.active {
    background: var(--bg-tertiary);
    color: var(--text-primary);
    font-weight: 600;
  }

  .content-area {
    flex: 1;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
  }

  .section-desc {
    font-size: 12px;
    color: var(--text-muted);
    margin-bottom: 12px;
  }

  .hotkey-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .hotkey-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 14px;
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
  }

  .hotkey-info {
    display: flex;
    flex-direction: column;
  }

  .hotkey-name {
    font-size: 13px;
    font-weight: 600;
  }

  .hotkey-id {
    font-size: 10px;
    color: var(--text-muted);
    font-family: monospace;
  }

  .hotkey-badge {
    font-family: monospace;
    font-size: 12px;
    padding: 4px 8px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: 4px;
    color: var(--text-primary);
    min-width: 80px;
    text-align: center;
    cursor: pointer;
    transition: all var(--transition);
  }

  .hotkey-badge:hover {
    border-color: var(--accent);
  }

  .hotkey-badge.recording {
    background: var(--accent);
    color: white;
    border-color: var(--accent);
  }

  .static-badge {
    font-family: monospace;
    font-size: 11px;
    padding: 4px 8px;
    background: var(--bg-tertiary);
    border-radius: 4px;
    color: var(--text-secondary);
  }

  .app-shortcuts {
    display: flex;
    flex-direction: column;
    gap: 12px;
  }

  .apps-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .primary-btn {
    padding: 6px 12px;
    background: var(--accent);
    color: #fff;
    font-weight: 600;
    font-size: 12px;
    border-radius: var(--radius-sm);
  }

  .add-form {
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-md);
    padding: 16px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    margin-bottom: 12px;
  }

  .form-row {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .form-label {
    font-size: 11px;
    font-weight: 600;
    color: var(--text-muted);
    text-transform: uppercase;
  }

  .form-row input, .form-row select {
    font-size: 13px;
    padding: 6px;
    width: 100%;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
  }

  .hotkey-input-btn {
    width: 100%;
    text-align: left;
    font-family: monospace;
    padding: 8px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
  }

  .hotkey-input-btn.recording {
    border-color: var(--accent);
    color: var(--accent);
  }

  .form-actions {
    display: flex;
    justify-content: flex-end;
  }

  .shortcuts-list {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .shortcut-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 10px 14px;
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
  }

  .shortcut-desc {
    font-size: 11px;
    color: var(--text-muted);
  }

  .shortcut-right {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .item-actions {
    display: flex;
    gap: 4px;
  }

  .icon-btn {
    padding: 4px;
    border-radius: 4px;
    font-size: 12px;
    background: transparent;
    transition: background var(--transition);
  }

  .icon-btn:hover {
    background: var(--bg-hover);
  }

  .icon-btn.danger:hover {
    background: rgba(239, 68, 68, 0.15);
  }

  .empty-state {
    text-align: center;
    padding: 20px;
    color: var(--text-muted);
    font-size: 13px;
  }
</style>
