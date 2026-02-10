<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { isProcessing, showNotification } from '../stores/app';
  import {
    ProcessText,
    GetActions,
    GetClipboardText,
    SetClipboardText
  } from '../../wailsjs/go/main/App';
  import { EventsOn } from '../../wailsjs/runtime/runtime';
  import type { config } from '../../wailsjs/go/models';

  let inputText = '';
  let outputText = '';
  let selectedActionID = 'correct';
  let targetLanguage = 'German';
  let actions: config.ActionConfig[] = [];
  let eventUnsubscribers: (() => void)[] = [];

  const languages = [
    'English', 'German', 'French', 'Spanish', 'Italian', 'Portuguese',
    'Dutch', 'Russian', 'Chinese', 'Japanese', 'Korean', 'Arabic'
  ];

  onMount(async () => {
    await loadActions();
    setupEventListeners();
  });

  onDestroy(() => {
    eventUnsubscribers.forEach(unsub => unsub());
  });

  async function loadActions() {
    try {
      actions = await GetActions() || [];
      // Ensure we have a selected action
      if (actions.length > 0 && !actions.find(a => a.id === selectedActionID)) {
        selectedActionID = actions[0].id;
      }
    } catch (err) {
      console.error('Failed to load actions:', err);
      showNotification('Failed to load actions', 'error');
    }
  }

  function setupEventListeners() {
    // Listen for menu/hotkey events
    const actionEvents = ['correct', 'email', 'outline', 'summarize', 'translate'];
    actionEvents.forEach(action => {
      eventUnsubscribers.push(EventsOn(`action:${action}`, () => {
        selectedActionID = action;
        // If we have input text, process immediately
        if (inputText.trim()) {
          processText();
        } else {
          // Otherwise try to paste from clipboard and process
          pasteFromClipboard().then(() => {
            if (inputText.trim()) processText();
          });
        }
      }));
    });

    eventUnsubscribers.push(EventsOn('action:paste-clipboard', () => {
      pasteFromClipboard();
    }));
  }

  export function setAction(actionID: string) {
    selectedActionID = actionID;
  }

  export async function pasteFromClipboard() {
    try {
      const text = await GetClipboardText();
      if (text) {
        inputText = text;
        showNotification('Pasted from clipboard', 'info');
      }
    } catch (err) {
      showNotification('Failed to read clipboard', 'error');
    }
  }

  async function processText() {
    if (!inputText.trim()) {
      showNotification('Please enter some text first', 'error');
      return;
    }

    isProcessing.set(true);
    outputText = '';

    try {
      const opts: Record<string, string> = {};
      if (selectedActionID === 'translate') {
        opts['targetLanguage'] = targetLanguage;
      }

      outputText = await ProcessText(selectedActionID, inputText, opts);
      showNotification('Text processed successfully', 'success');
    } catch (err: any) {
      showNotification(err?.message || 'Processing failed', 'error');
      outputText = `Error: ${err?.message || 'Processing failed'}`;
    } finally {
      isProcessing.set(false);
    }
  }

  async function copyOutput() {
    if (!outputText) return;
    try {
      await SetClipboardText(outputText);
      showNotification('Copied to clipboard', 'success');
    } catch {
      showNotification('Failed to copy', 'error');
    }
  }

  function clearAll() {
    inputText = '';
    outputText = '';
  }

  function swapTexts() {
    const temp = inputText;
    inputText = outputText;
    outputText = temp;
  }
</script>

<div class="text-processor">
  <div class="tp-header">
    <h2>Text Processing</h2>
  </div>

  <!-- Action selector -->
  <div class="action-bar">
    {#each actions as action}
      <button
        class="action-btn"
        class:active={selectedActionID === action.id}
        on:click={() => selectedActionID = action.id}
        title={action.description}
      >
        <span class="action-label">{action.name}</span>
        <span class="action-desc">{action.description}</span>
      </button>
    {/each}
  </div>

  <!-- Language selector for translate -->
  {#if selectedActionID === 'translate'}
    <div class="language-bar">
      <label>
        Translate to:
        <select bind:value={targetLanguage}>
          {#each languages as lang}
            <option value={lang}>{lang}</option>
          {/each}
        </select>
      </label>
    </div>
  {/if}

  <!-- Text areas -->
  <div class="text-panels">
    <div class="panel input-panel">
      <div class="panel-header">
        <span class="panel-title">Input</span>
        <div class="panel-actions">
          <button class="small-btn" on:click={pasteFromClipboard} title="Paste from clipboard">
            Paste
          </button>
          <button class="small-btn" on:click={clearAll}>Clear</button>
        </div>
      </div>
      <textarea
        class="text-area"
        bind:value={inputText}
        placeholder="Paste or type your text here..."
        spellcheck="false"
      ></textarea>
    </div>

    <div class="panel-divider">
      <button class="swap-btn" on:click={swapTexts} title="Swap input/output">
        &#8646;
      </button>
    </div>

    <div class="panel output-panel">
      <div class="panel-header">
        <span class="panel-title">Output</span>
        <div class="panel-actions">
          <button class="small-btn" on:click={copyOutput} disabled={!outputText}>
            Copy
          </button>
        </div>
      </div>
      <textarea
        class="text-area output"
        bind:value={outputText}
        placeholder="Processed text will appear here..."
        readonly
      ></textarea>
    </div>
  </div>

  <!-- Process button -->
  <div class="process-bar">
    <button
      class="process-btn"
      on:click={processText}
      disabled={$isProcessing || !inputText.trim()}
    >
      {#if $isProcessing}
        Processing...
      {:else}
        Process Text
      {/if}
    </button>
  </div>
</div>

<style>
  .text-processor {
    display: flex;
    flex-direction: column;
    height: 100%;
    padding: 0 20px 20px;
    gap: 12px;
    overflow: hidden;
  }

  .tp-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .tp-header h2 {
    font-size: 16px;
    font-weight: 600;
  }

  .action-bar {
    display: flex;
    gap: 6px;
    flex-wrap: wrap;
  }

  .action-btn {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    padding: 8px 12px;
    border-radius: var(--radius-sm);
    background: transparent;
    border: 1px solid transparent;
    transition: all var(--transition);
    min-width: 0;
  }

  .action-btn:hover {
    background: var(--bg-hover);
  }

  .action-btn.active {
    background: var(--bg-tertiary);
    color: var(--text-primary);
    box-shadow: inset 0 0 0 1px var(--bg-active);
  }

  .action-label {
    font-size: 12px;
    font-weight: 600;
    white-space: nowrap;
  }

  .action-btn.active .action-label {
    color: var(--accent);
  }

  .action-desc {
    font-size: 10px;
    color: var(--text-muted);
    white-space: nowrap;
  }

  /* ... language bar ... */

  .text-panels {
    display: flex;
    gap: 12px;
    flex: 1;
    min-height: 0;
    overflow: hidden;
  }

  .panel {
    flex: 1;
    display: flex;
    flex-direction: column;
    min-width: 0;
    background: var(--bg-secondary);
    border-radius: var(--radius-md);
    padding: 12px;
  }

  .panel-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding-bottom: 8px;
    margin-bottom: 4px;
    border-bottom: 1px solid var(--border-color);
  }

  .panel-title {
    font-size: 10px;
    font-weight: 700;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  /* ... panel actions ... */

  .small-btn {
    padding: 2px 8px;
    font-size: 10px;
    border-radius: 4px;
    color: var(--text-muted);
    background: transparent;
    transition: all var(--transition);
    border: 1px solid transparent;
  }

  .small-btn:hover:not(:disabled) {
    color: var(--text-primary);
    background: var(--bg-hover);
  }

  /* ... divider ... */

  .swap-btn {
    width: 24px;
    height: 24px;
    border-radius: 50%;
    background: var(--bg-secondary);
    color: var(--text-muted);
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 12px;
    transition: all var(--transition);
    border: 1px solid var(--border-color);
  }

  .swap-btn:hover {
    border-color: var(--text-primary);
    color: var(--text-primary);
  }

  .text-area {
    flex: 1;
    resize: none;
    padding: 0;
    font-size: 13px;
    line-height: 1.6;
    background: transparent;
    border: none;
    color: var(--text-primary);
    min-height: 0;
    outline: none;
  }

  .text-area:focus {
    outline: none;
    box-shadow: none;
  }

  .text-area.output {
    background: transparent;
    color: var(--text-secondary);
  }

  .text-area::placeholder {
    color: var(--text-muted);
    font-style: italic;
  }

  .process-bar {
    display: flex;
    justify-content: flex-end;
    padding-top: 4px;
  }

  .process-btn {
    padding: 8px 32px;
    background: var(--text-primary); /* Raycast often uses white for primary action */
    color: var(--bg-primary);
    font-weight: 600;
    font-size: 12px;
    border-radius: var(--radius-sm);
    transition: all var(--transition);
  }

  .process-btn:hover:not(:disabled) {
    background: #ffffff;
    box-shadow: 0 0 12px rgba(255, 255, 255, 0.3);
  }
</style>
