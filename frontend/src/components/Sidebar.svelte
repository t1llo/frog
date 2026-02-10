<script lang="ts">
  import { currentView } from '../stores/app';
  import type { View } from '../stores/app';

  const navItems: { id: View; label: string; icon: string }[] = [
    { id: 'text', label: 'Text', icon: 'T' },
    { id: 'models', label: 'Models', icon: 'M' },
    { id: 'shortcuts', label: 'Shortcuts', icon: 'S' },
    { id: 'settings', label: 'Settings', icon: 'G' },
  ];

  function navigate(view: View) {
    currentView.set(view);
  }
</script>

<aside class="sidebar">
  <div class="sidebar-drag-region"></div>
  <div class="sidebar-logo">
    <span class="logo-text">frog</span>
  </div>
  <nav class="sidebar-nav">
    {#each navItems as item}
      <button
        class="nav-item"
        class:active={$currentView === item.id}
        on:click={() => navigate(item.id)}
      >
        <span class="nav-icon">{item.icon}</span>
        <span class="nav-label">{item.label}</span>
      </button>
    {/each}
  </nav>
</aside>

<style>
  .sidebar {
    width: 200px;
    min-width: 200px;
    background: var(--bg-secondary);
    /* No border, just subtle background difference */
    display: flex;
    flex-direction: column;
    height: 100%;
    padding: 8px;
  }

  .sidebar-drag-region {
    height: 28px;
    flex-shrink: 0;
    --wails-draggable: drag;
  }

  .sidebar-logo {
    padding: 0 12px 12px;
    margin-bottom: 4px;
    display: flex;
    align-items: center;
  }

  .logo-text {
    font-size: 14px;
    font-weight: 700;
    color: var(--text-primary);
    letter-spacing: -0.02em;
    opacity: 0.9;
  }

  .sidebar-nav {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .nav-item {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 6px 10px;
    border-radius: var(--radius-sm);
    color: var(--text-secondary);
    transition: all var(--transition);
    text-align: left;
    width: 100%;
    font-size: 13px;
  }

  .nav-item:hover {
    background: var(--bg-hover);
    color: var(--text-primary);
  }

  .nav-item.active {
    background: var(--bg-tertiary);
    color: var(--text-primary);
    box-shadow: inset 2px 0 0 var(--accent); /* Left accent bar */
  }

  /* Optional: highlight icon */
  .nav-item.active .nav-icon {
    color: var(--text-primary);
    background: transparent;
  }

  .nav-icon {
    width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-weight: 600;
    font-size: 10px;
    color: var(--text-muted);
    border: 1px solid var(--bg-active);
    border-radius: 3px;
    flex-shrink: 0;
  }

  .nav-item:hover .nav-icon {
    border-color: var(--text-secondary);
    color: var(--text-secondary);
  }

  .nav-label {
    font-weight: 500;
  }
</style>
