<script lang="ts">
  import { onMount, onDestroy, createEventDispatcher } from 'svelte';
  import { fade, scale } from 'svelte/transition';
  import { ReplaceSelectedText, PasteBelowCursor, CopyToClipboard } from '../../wailsjs/go/main/App';
  import { showNotification } from '../stores/app';

  export let visible = false;
  export let actionName = '';
  export let originalText = '';
  export let processedText = '';
  export let loading = false;
  export let error: string | null = null;

  const dispatch = createEventDispatcher<{ dismiss: void }>();
  let autoDismissTimer: ReturnType<typeof setTimeout> | null = null;
  let copiedFeedback = false;

  const AUTO_DISMISS_MS = 30000;

  onMount(() => {
    window.addEventListener('keydown', handleKeydown);
  });

  onDestroy(() => {
    window.removeEventListener('keydown', handleKeydown);
    clearAutoDismissTimer();
  });

  $: if (visible && !loading) {
    startAutoDismissTimer();
  } else if (!visible) {
    clearAutoDismissTimer();
  }

  function startAutoDismissTimer() {
    clearAutoDismissTimer();
    autoDismissTimer = setTimeout(() => {
      dismiss();
    }, AUTO_DISMISS_MS);
  }

  function clearAutoDismissTimer() {
    if (autoDismissTimer) {
      clearTimeout(autoDismissTimer);
      autoDismissTimer = null;
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    if (visible && e.key === 'Escape') {
      e.preventDefault();
      dismiss();
    }
  }

  function dismiss() {
    clearAutoDismissTimer();
    dispatch('dismiss');
  }

  async function handleReplace() {
    try {
      await ReplaceSelectedText(processedText);
      showNotification('Text replaced', 'success');
      dismiss();
    } catch (err: any) {
      showNotification(err?.message || 'Failed to replace text', 'error');
    }
  }

  async function handlePasteBelow() {
    try {
      await PasteBelowCursor(processedText);
      showNotification('Text pasted below cursor', 'success');
      dismiss();
    } catch (err: any) {
      showNotification(err?.message || 'Failed to paste text', 'error');
    }
  }

  async function handleCopy() {
    try {
      await CopyToClipboard(processedText);
      copiedFeedback = true;
      showNotification('Copied to clipboard', 'success');
      setTimeout(() => {
        copiedFeedback = false;
      }, 1500);
    } catch (err: any) {
      showNotification(err?.message || 'Failed to copy', 'error');
    }
  }

  function handleMouseEnter() {
    clearAutoDismissTimer();
  }

  function handleMouseLeave() {
    if (visible && !loading) {
      startAutoDismissTimer();
    }
  }
</script>

{#if visible}
  <div class="popup-overlay" transition:fade={{ duration: 150 }}>
    <div
      class="popup-container"
      transition:scale={{ duration: 200, start: 0.95 }}
      on:mouseenter={handleMouseEnter}
      on:mouseleave={handleMouseLeave}
    >
      <!-- Header -->
      <div class="popup-header">
        <div class="header-title">
          {#if loading}
            <span class="loading-spinner"></span>
          {/if}
          <span class="action-name">{loading ? 'Processing...' : actionName}</span>
        </div>
        <button class="dismiss-btn" on:click={dismiss} title="Dismiss (Esc)">
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
            <path d="M1 1L6 6M6 6L11 1M6 6L1 11M6 6L11 11" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
          </svg>
        </button>
      </div>

      <!-- Content -->
      <div class="popup-content">
        {#if error}
          <div class="error-message">
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
              <circle cx="8" cy="8" r="7" stroke="currentColor" stroke-width="1.5"/>
              <path d="M8 5V8M8 10V10.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
            </svg>
            <span>{error}</span>
          </div>
        {:else if loading}
          <div class="loading-container">
            <div class="loading-dots">
              <span></span>
              <span></span>
              <span></span>
            </div>
            <span class="loading-text">Processing your text...</span>
          </div>
        {:else}
          <div class="result-container">
            <div class="result-scroll">
              <pre class="result-text">{processedText}</pre>
            </div>
          </div>
        {/if}
      </div>

      <!-- Actions -->
      {#if !loading && !error}
        <div class="popup-actions">
          <button class="action-btn primary" on:click={handleReplace}>
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
              <path d="M2 6H10M7 3L10 6L7 9" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
            Replace
          </button>
          <button class="action-btn secondary" on:click={handlePasteBelow}>
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
              <path d="M6 2V8M6 8L3 5M6 8L9 5M2 10H10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
            Paste Below
          </button>
          <button class="action-btn secondary" on:click={handleCopy} class:copied={copiedFeedback}>
            {#if copiedFeedback}
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                <path d="M2 6L5 9L10 3" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
              </svg>
              Copied!
            {:else}
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                <rect x="3" y="3" width="6" height="6" rx="1" stroke="currentColor" stroke-width="1.5"/>
                <path d="M5 1H9C9.55228 1 10 1.44772 10 2V6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
              </svg>
              Copy
            {/if}
          </button>
          <button class="action-btn tertiary" on:click={dismiss}>
            Dismiss
          </button>
        </div>
      {/if}
    </div>
  </div>
{/if}

<style>
  .popup-overlay {
    position: fixed;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0, 0, 0, 0.6);
    backdrop-filter: blur(4px);
    z-index: 1000;
  }

  .popup-container {
    width: 400px;
    max-width: calc(100vw - 40px);
    background: var(--bg-secondary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-lg);
    overflow: hidden;
  }

  .popup-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 16px;
    border-bottom: 1px solid var(--border-color);
    background: var(--bg-tertiary);
  }

  .header-title {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .action-name {
    font-size: 13px;
    font-weight: 600;
    color: var(--text-primary);
  }

  .loading-spinner {
    width: 14px;
    height: 14px;
    border: 2px solid var(--border-color);
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .dismiss-btn {
    width: 24px;
    height: 24px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: var(--radius-sm);
    color: var(--text-muted);
    transition: all var(--transition);
  }

  .dismiss-btn:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .popup-content {
    padding: 16px;
    min-height: 80px;
    max-height: 300px;
  }

  .loading-container {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 12px;
    height: 100px;
  }

  .loading-dots {
    display: flex;
    gap: 4px;
  }

  .loading-dots span {
    width: 6px;
    height: 6px;
    background: var(--accent);
    border-radius: 50%;
    animation: bounce 1.4s ease-in-out infinite both;
  }

  .loading-dots span:nth-child(1) { animation-delay: -0.32s; }
  .loading-dots span:nth-child(2) { animation-delay: -0.16s; }

  @keyframes bounce {
    0%, 80%, 100% { transform: scale(0.6); opacity: 0.5; }
    40% { transform: scale(1); opacity: 1; }
  }

  .loading-text {
    font-size: 12px;
    color: var(--text-secondary);
  }

  .error-message {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 12px;
    background: rgba(255, 69, 58, 0.1);
    border: 1px solid var(--danger);
    border-radius: var(--radius-md);
    color: var(--danger);
    font-size: 12px;
  }

  .result-container {
    background: var(--bg-primary);
    border: 1px solid var(--border-color);
    border-radius: var(--radius-md);
    overflow: hidden;
  }

  .result-scroll {
    max-height: 268px;
    overflow-y: auto;
    padding: 12px;
  }

  .result-text {
    margin: 0;
    font-family: inherit;
    font-size: 13px;
    line-height: 1.6;
    color: var(--text-primary);
    white-space: pre-wrap;
    word-wrap: break-word;
  }

  .popup-actions {
    display: flex;
    gap: 8px;
    padding: 12px 16px;
    border-top: 1px solid var(--border-color);
    background: var(--bg-tertiary);
  }

  .action-btn {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 12px;
    font-size: 12px;
    font-weight: 500;
    border-radius: var(--radius-sm);
    transition: all var(--transition);
    flex: 1;
    justify-content: center;
  }

  .action-btn.primary {
    background: var(--text-primary);
    color: var(--bg-primary);
  }

  .action-btn.primary:hover {
    background: #ffffff;
    box-shadow: 0 0 12px rgba(255, 255, 255, 0.2);
  }

  .action-btn.secondary {
    background: var(--bg-hover);
    color: var(--text-primary);
    border: 1px solid var(--border-color);
  }

  .action-btn.secondary:hover {
    background: var(--bg-active);
    border-color: var(--text-muted);
  }

  .action-btn.secondary.copied {
    background: var(--accent-muted);
    color: var(--accent);
    border-color: var(--accent);
  }

  .action-btn.tertiary {
    background: transparent;
    color: var(--text-muted);
    flex: 0 0 auto;
    padding: 8px;
  }

  .action-btn.tertiary:hover {
    color: var(--text-primary);
  }
</style>
