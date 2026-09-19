<script lang="ts">
  import { onMount } from 'svelte';
  import { showNotification } from '../stores/app';
  import {
    GetLLMConfig,
    SaveLLMConfig,
    GetTextProcessingConfig,
    SaveTextProcessingConfig,
    GetActiveProviderName,
    GetActions,
    SaveAction,
    DeleteAction,
    Quit
  } from '../../wailsjs/go/main/App';
  import type { config } from '../../wailsjs/go/models';

  // LLM config state
  let activeProvider = 'local';
  let activeProviderName = 'None';

  // Remote providers
  interface RemoteProvider {
    id: string;
    name: string;
    type: string;
    apiKey: string;
    endpoint: string;
    model: string;
    active: boolean;
  }

  let remoteProviders: RemoteProvider[] = [];

  // Text processing config
  let defaultLanguage = 'en';
  let translateTo = 'de';

  // Actions & Prompts state
  let actions: config.ActionConfig[] = [];
  let editingAction: config.ActionConfig | null = null;
  let showActionEditor = false;

  const providerTypes = [
    { value: 'openai', label: 'OpenAI' },
    { value: 'anthropic', label: 'Anthropic' },
    { value: 'custom', label: 'Custom (OpenAI-compatible)' },
  ];

  const languages = [
    { code: 'en', name: 'English' },
    { code: 'de', name: 'German' },
    { code: 'fr', name: 'French' },
    { code: 'es', name: 'Spanish' },
    { code: 'it', name: 'Italian' },
    { code: 'pt', name: 'Portuguese' },
    { code: 'nl', name: 'Dutch' },
    { code: 'ru', name: 'Russian' },
    { code: 'zh', name: 'Chinese' },
    { code: 'ja', name: 'Japanese' },
    { code: 'ko', name: 'Korean' },
  ];

  onMount(async () => {
    await loadConfig();
    await loadActions();
  });

  async function loadConfig() {
    try {
      const llmCfg = await GetLLMConfig();
      activeProvider = llmCfg.activeProvider || 'local';
      remoteProviders = llmCfg.remoteProviders || [];

      const tpCfg = await GetTextProcessingConfig();
      defaultLanguage = tpCfg.defaultLanguage || 'en';
      translateTo = tpCfg.translateTo || 'de';

      activeProviderName = await GetActiveProviderName();
    } catch (err: any) {
      showNotification('Failed to load settings', 'error');
    }
  }

  async function loadActions() {
    try {
      actions = await GetActions() || [];
    } catch (err) {
      showNotification('Failed to load actions', 'error');
    }
  }

  async function saveLLMConfig() {
    try {
      const llmCfg = await GetLLMConfig();
      // Cast to any to bypass class method checks
      await SaveLLMConfig({
        activeProvider,
        local: llmCfg.local,
        remoteProviders: remoteProviders as any,
      } as any);
      activeProviderName = await GetActiveProviderName();
      showNotification('LLM settings saved', 'success');
    } catch (err: any) {
      showNotification(err?.message || 'Failed to save LLM settings', 'error');
    }
  }

  async function saveTextConfig() {
    try {
      const tpCfg = await GetTextProcessingConfig();
      await SaveTextProcessingConfig({
        defaultLanguage,
        translateTo,
        actions: tpCfg.actions // Preserve existing actions
      } as any);
      showNotification('Text processing settings saved', 'success');
    } catch (err: any) {
      showNotification(err?.message || 'Failed to save', 'error');
    }
  }

  // --- Remote Provider Management ---

  function addRemoteProvider() {
    remoteProviders = [...remoteProviders, {
      id: `provider-${Date.now()}`,
      name: 'New Provider',
      type: 'openai',
      apiKey: '',
      endpoint: 'https://api.openai.com/v1',
      model: 'gpt-4o-mini',
      active: false,
    }];
  }

  function removeProvider(id: string) {
    remoteProviders = remoteProviders.filter(p => p.id !== id);
  }

  function setActiveRemoteProvider(id: string) {
    remoteProviders = remoteProviders.map(p => ({
      ...p,
      active: p.id === id,
    }));
    activeProvider = 'remote';
  }

  // --- Action Management ---

  function openActionEditor(action?: config.ActionConfig) {
    if (action) {
      // Clone to avoid direct mutation
      editingAction = JSON.parse(JSON.stringify(action));
    } else {
      // New action
      editingAction = {
        id: `custom-${Date.now()}`,
        name: 'New Action',
        description: 'Custom text processing action',
        systemPrompt: 'You are a helpful assistant.',
        userPrompt: 'Please process the following text:\n\n{{text}}',
        builtin: false,
        icon: 'C'
      };
    }
    showActionEditor = true;
  }

  function closeActionEditor() {
    showActionEditor = false;
    editingAction = null;
  }

  async function saveAction() {
    if (!editingAction) return;
    try {
      await SaveAction(editingAction);
      showNotification('Action saved', 'success');
      await loadActions();
      closeActionEditor();
    } catch (err: any) {
      showNotification(err?.message || 'Failed to save action', 'error');
    }
  }

  async function deleteAction(id: string) {
    if (!confirm('Are you sure you want to delete this action?')) return;
    try {
      await DeleteAction(id);
      showNotification('Action deleted', 'success');
      await loadActions();
    } catch (err: any) {
      showNotification(err?.message || 'Failed to delete action', 'error');
    }
  }

  function quitApp() {
    try {
      Quit();
    } catch (err) {
      console.error(err);
    }
  }
</script>

<div class="settings">
  <div class="settings-header">
    <h2>Settings</h2>
    <div class="provider-status">
      Active: <span class="provider-name">{activeProviderName}</span>
    </div>
  </div>

  {#if showActionEditor && editingAction}
    <div class="action-editor-overlay">
      <div class="action-editor">
        <h3>{editingAction.builtin ? 'View Built-in Action' : 'Edit Action'}</h3>
        
        <div class="form-row">
          <label>
            <span class="form-label">Name</span>
            <input type="text" bind:value={editingAction.name} disabled={editingAction.builtin} />
          </label>
        </div>

        <div class="form-row">
          <label>
            <span class="form-label">Description</span>
            <input type="text" bind:value={editingAction.description} disabled={editingAction.builtin} />
          </label>
        </div>

        <div class="form-row">
          <label>
            <span class="form-label">System Prompt</span>
            <textarea class="prompt-area" bind:value={editingAction.systemPrompt} disabled={editingAction.builtin}></textarea>
          </label>
        </div>

        <div class="form-row">
          <label>
            <span class="form-label">User Prompt</span>
            <div class="prompt-hint">Use <code>{'{{text}}'}</code> for input and <code>{'{{targetLanguage}}'}</code> for language.</div>
            <textarea class="prompt-area" bind:value={editingAction.userPrompt} disabled={editingAction.builtin}></textarea>
          </label>
        </div>

        <div class="editor-actions">
          <button class="secondary-btn" on:click={closeActionEditor}>Close</button>
          {#if !editingAction.builtin}
            <button class="primary-btn" on:click={saveAction}>Save Action</button>
          {/if}
        </div>
      </div>
    </div>
  {/if}

  <!-- Actions & Prompts Settings -->
  <div class="section">
    <div class="section-header">
      <h3>Actions & Prompts</h3>
      <button class="small-btn" on:click={() => openActionEditor()}>+ New Action</button>
    </div>
    
    <div class="actions-list">
      {#each actions as action}
        <div class="action-item" on:click={() => openActionEditor(action)}>
          <div class="action-icon">{action.icon || 'A'}</div>
          <div class="action-info">
            <div class="action-name">
              {action.name}
              {#if action.builtin}<span class="builtin-badge">Built-in</span>{/if}
            </div>
            <div class="action-desc">{action.description}</div>
          </div>
          {#if !action.builtin}
            <button class="icon-btn danger" on:click|stopPropagation={() => deleteAction(action.id)} title="Delete">
              🗑️
            </button>
          {/if}
        </div>
      {/each}
    </div>
  </div>

  <!-- LLM Provider Settings -->
  <div class="section">
    <h3>LLM Provider</h3>

    <div class="provider-toggle">
      <button
        class="toggle-btn"
        class:active={activeProvider === 'local'}
        on:click={() => { activeProvider = 'local'; }}
      >
        Local
      </button>
      <button
        class="toggle-btn"
        class:active={activeProvider === 'remote'}
        on:click={() => { activeProvider = 'remote'; }}
      >
        Remote API
      </button>
    </div>

    {#if activeProvider === 'local'}
      <div class="config-group">
        <p class="config-hint">Local models are managed in the Models tab. Download a model there and it will run directly inside Frog.</p>
      </div>
    {:else}
      <div class="remote-providers">
        {#each remoteProviders as provider, i}
          <div class="provider-card" class:active={provider.active}>
            <div class="provider-card-header">
              <input
                type="text"
                bind:value={provider.name}
                class="provider-name-input"
                placeholder="Provider name"
              />
              <div class="provider-card-actions">
                {#if !provider.active}
                  <button class="small-btn accent" on:click={() => setActiveRemoteProvider(provider.id)}>
                    Activate
                  </button>
                {:else}
                  <span class="active-badge">Active</span>
                {/if}
                <button class="small-btn danger" on:click={() => removeProvider(provider.id)}>
                  Remove
                </button>
              </div>
            </div>

            <div class="provider-fields">
              <div class="form-row">
                <label>
                  <span class="form-label">Type</span>
                  <select bind:value={provider.type}>
                    {#each providerTypes as pt}
                      <option value={pt.value}>{pt.label}</option>
                    {/each}
                  </select>
                </label>
              </div>

              <div class="form-row">
                <label>
                  <span class="form-label">API Key</span>
                  <input type="password" bind:value={provider.apiKey} placeholder="sk-..." />
                </label>
              </div>

              <div class="form-row">
                <label>
                  <span class="form-label">Endpoint</span>
                  <input type="text" bind:value={provider.endpoint} placeholder="https://api.openai.com/v1" />
                </label>
              </div>

              <div class="form-row">
                <label>
                  <span class="form-label">Model</span>
                  <input type="text" bind:value={provider.model} placeholder="gpt-4o-mini" />
                </label>
              </div>
            </div>
          </div>
        {/each}

        <button class="add-provider-btn" on:click={addRemoteProvider}>
          + Add Provider
        </button>
      </div>
    {/if}

    <div class="section-actions">
      <button class="primary-btn" on:click={saveLLMConfig}>Save LLM Settings</button>
    </div>
  </div>

  <!-- Text Processing Settings -->
  <div class="section">
    <h3>Text Processing Defaults</h3>
    <div class="config-group">
      <div class="form-row">
        <label>
          <span class="form-label">Default Language</span>
          <select bind:value={defaultLanguage}>
            {#each languages as lang}
              <option value={lang.code}>{lang.name}</option>
            {/each}
          </select>
        </label>
      </div>
      <div class="form-row">
        <label>
          <span class="form-label">Default Translation Target</span>
          <select bind:value={translateTo}>
            {#each languages as lang}
              <option value={lang.code}>{lang.name}</option>
            {/each}
          </select>
        </label>
      </div>
    </div>
    <div class="section-actions">
      <button class="primary-btn" on:click={saveTextConfig}>Save Text Settings</button>
    </div>
  </div>

  <div class="section" style="border: none;">
    <button class="primary-btn danger-zone" on:click={quitApp} style="width: 100%;">
      Quit Frog
    </button>
  </div>
</div>

<style>
  .settings {
    display: flex;
    flex-direction: column;
    height: 100%;
    padding: 0 20px 20px;
    gap: 20px;
    overflow-y: auto;
    position: relative;
  }

  .settings-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .settings-header h2 {
    font-size: 16px;
    font-weight: 600;
  }

  .provider-status {
    font-size: 12px;
    color: var(--text-muted);
  }

  .provider-name {
    color: var(--accent);
    font-weight: 600;
  }

  .section {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding-bottom: 20px;
    border-bottom: 1px solid var(--border-color);
  }

  .section:last-child {
    border-bottom: none;
  }

  .section-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .section h3 {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-secondary);
  }

  .actions-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .action-item {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px;
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    cursor: pointer;
    transition: all var(--transition);
  }

  .action-item:hover {
    border-color: var(--text-muted);
  }

  .action-icon {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--bg-tertiary);
    border-radius: 6px;
    font-weight: 600;
    color: var(--accent);
  }

  .action-info {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .action-name {
    font-size: 13px;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .builtin-badge {
    font-size: 10px;
    background: var(--bg-tertiary);
    padding: 1px 5px;
    border-radius: 4px;
    color: var(--text-muted);
    font-weight: normal;
  }

  .action-desc {
    font-size: 11px;
    color: var(--text-muted);
  }

  .icon-btn {
    padding: 6px;
    background: transparent;
    border-radius: 4px;
    font-size: 12px;
    transition: background var(--transition);
  }

  .icon-btn:hover {
    background: var(--bg-hover);
  }

  .icon-btn.danger:hover {
    background: rgba(239, 68, 68, 0.15);
  }

  .action-editor-overlay {
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    background: rgba(0, 0, 0, 0.7);
    backdrop-filter: blur(2px);
    z-index: 100;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 20px;
  }

  .action-editor {
    background: var(--bg-primary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-md);
    padding: 20px;
    width: 100%;
    max-width: 500px;
    max-height: 90%;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 16px;
    box-shadow: 0 10px 30px rgba(0,0,0,0.5);
  }

  .action-editor h3 {
    font-size: 16px;
    font-weight: 600;
    margin-bottom: 4px;
  }

  .prompt-area {
    min-height: 100px;
    font-family: monospace;
    font-size: 12px;
    resize: vertical;
    padding: 8px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
  }

  .prompt-hint {
    font-size: 11px;
    color: var(--text-muted);
    margin-bottom: 4px;
  }

  .prompt-hint code {
    background: var(--bg-tertiary);
    padding: 1px 4px;
    border-radius: 3px;
  }

  .editor-actions {
    display: flex;
    justify-content: flex-end;
    gap: 8px;
    margin-top: 8px;
  }

  .provider-toggle {
    display: flex;
    gap: 4px;
    background: var(--bg-secondary);
    border-radius: var(--radius-md);
    padding: 3px;
    border: 1px solid var(--border-color);
    width: fit-content;
  }

  .toggle-btn {
    padding: 6px 16px;
    font-size: 12px;
    font-weight: 500;
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    transition: all var(--transition);
  }

  .toggle-btn.active {
    background: var(--accent);
    color: #fff;
  }

  .toggle-btn:hover:not(.active) {
    color: var(--text-primary);
    background: var(--bg-hover);
  }

  .config-group {
    display: flex;
    flex-direction: column;
    gap: 10px;
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-md);
    padding: 14px;
  }

  .config-hint {
    font-size: 12px;
    color: var(--text-muted);
    line-height: 1.5;
  }

  .form-row {
    display: flex;
    flex-direction: column;
  }

  .form-row label {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .form-label {
    font-size: 11px;
    font-weight: 600;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .form-row input, .form-row select {
    font-size: 13px;
    width: 100%;
    padding: 8px;
    background: var(--bg-tertiary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-sm);
    color: var(--text-primary);
  }
  
  .form-row input:disabled, .form-row textarea:disabled {
    opacity: 0.7;
    cursor: not-allowed;
  }

  .remote-providers {
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .provider-card {
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-md);
    padding: 14px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .provider-card.active {
    border-color: var(--accent);
  }

  .provider-card-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }

  .provider-name-input {
    font-size: 14px;
    font-weight: 600;
    background: transparent;
    border: none;
    padding: 0;
    color: var(--text-primary);
    flex: 1;
  }

  .provider-name-input:focus {
    border: none;
    outline: none;
  }

  .provider-card-actions {
    display: flex;
    gap: 6px;
    align-items: center;
  }

  .provider-fields {
    display: flex;
    flex-direction: column;
    gap: 8px;
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

  .active-badge {
    background: var(--accent);
    color: #fff;
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 10px;
    font-weight: 600;
  }

  .add-provider-btn {
    padding: 10px;
    border: 1px dashed var(--border-color);
    border-radius: var(--radius-md);
    color: var(--text-muted);
    font-size: 13px;
    transition: all var(--transition);
  }

  .add-provider-btn:hover {
    border-color: var(--accent);
    color: var(--accent);
    background: var(--accent-muted);
  }

  .section-actions {
    display: flex;
    justify-content: flex-end;
  }

  .primary-btn {
    padding: 8px 16px;
    background: var(--accent);
    color: #fff;
    font-weight: 600;
    font-size: 12px;
    border-radius: var(--radius-sm);
    transition: all var(--transition);
  }

  .primary-btn:hover {
    background: var(--accent-hover);
  }
  
  .secondary-btn {
    padding: 8px 16px;
    background: var(--bg-tertiary);
    color: var(--text-secondary);
    font-weight: 500;
    font-size: 12px;
    border-radius: var(--radius-sm);
    transition: all var(--transition);
  }

  .secondary-btn:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .danger-zone {
    background: rgba(239, 68, 68, 0.1);
    color: var(--danger);
    border: 1px solid var(--danger);
  }

  .danger-zone:hover {
    background: var(--danger);
    color: white;
  }
</style>
