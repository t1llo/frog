<script lang="ts">
  import Sidebar from './components/Sidebar.svelte';
  import TextProcessor from './components/TextProcessor.svelte';
  import ModelManager from './components/ModelManager.svelte';
  import ShortcutsManager from './components/ShortcutsManager.svelte';
  import Settings from './components/Settings.svelte';
  import Notification from './components/Notification.svelte';
  import PopupResult from './components/PopupResult.svelte';
  import { currentView } from './stores/app';
  import { EventsOn } from '../wailsjs/runtime/runtime';
  import { onMount } from 'svelte';

  let textProcessorRef: TextProcessor;

  // Popup state
  let popupVisible = false;
  let popupActionName = '';
  let popupOriginalText = '';
  let popupProcessedText = '';
  let popupLoading = false;
  let popupError: string | null = null;

  onMount(() => {
    // Listen for menu bar action events
    EventsOn('action:correct', () => {
      currentView.set('text');
      if (textProcessorRef) textProcessorRef.setAction('correct');
    });
    EventsOn('action:email', () => {
      currentView.set('text');
      if (textProcessorRef) textProcessorRef.setAction('email');
    });
    EventsOn('action:outline', () => {
      currentView.set('text');
      if (textProcessorRef) textProcessorRef.setAction('outline');
    });
    EventsOn('action:summarize', () => {
      currentView.set('text');
      if (textProcessorRef) textProcessorRef.setAction('summarize');
    });
    EventsOn('action:translate', () => {
      currentView.set('text');
      if (textProcessorRef) textProcessorRef.setAction('translate');
    });
    EventsOn('action:paste-clipboard', () => {
      currentView.set('text');
      if (textProcessorRef) textProcessorRef.pasteFromClipboard();
    });

    // Listen for popup result events
    EventsOn('popup:result', (data: { actionName: string; originalText: string; processedText: string }) => {
      popupActionName = data.actionName;
      popupOriginalText = data.originalText;
      popupProcessedText = data.processedText;
      popupVisible = true;
      popupLoading = false;
      popupError = null;
    });
  });
</script>

<div class="app-layout">
  <Sidebar />
  <main class="main-content">
    <div class="titlebar-spacer"></div>
    {#if $currentView === 'text'}
      <TextProcessor bind:this={textProcessorRef} />
    {:else if $currentView === 'models'}
      <ModelManager />
    {:else if $currentView === 'shortcuts'}
      <ShortcutsManager />
    {:else if $currentView === 'settings'}
      <Settings />
    {/if}
  </main>
  <Notification />
  
  {#if popupVisible}
    <div class="popup-overlay">
      <PopupResult
        actionName={popupActionName}
        originalText={popupOriginalText}
        processedText={popupProcessedText}
        loading={popupLoading}
        error={popupError}
        on:close={() => popupVisible = false}
      />
    </div>
  {/if}
</div>

<style>
  .app-layout {
    display: flex;
    height: 100%;
    overflow: hidden;
  }

  .main-content {
    flex: 1;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    min-width: 0;
  }

  .titlebar-spacer {
    height: 38px;
    flex-shrink: 0;
    --wails-draggable: drag;
  }

  .popup-overlay {
    position: fixed;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0, 0, 0, 0.5);
    z-index: 9999;
  }
</style>
