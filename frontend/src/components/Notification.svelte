<script lang="ts">
  import { notification } from '../stores/app';
  import { fade } from 'svelte/transition';
</script>

{#if $notification}
  <div
    class="notification {$notification.type}"
    transition:fade={{ duration: 200 }}
  >
    {$notification.message}
  </div>
{/if}

<style>
  .notification {
    position: fixed;
    bottom: 20px;
    right: 20px;
    padding: 10px 16px;
    border-radius: var(--radius-md);
    font-size: 13px;
    font-weight: 500;
    z-index: 1000;
    box-shadow: var(--shadow-lg);
    max-width: 350px;
  }

  .notification.success {
    background: var(--accent);
    color: #fff;
  }

  .notification.error {
    background: var(--danger);
    color: #fff;
  }

  .notification.info {
    background: var(--bg-tertiary);
    color: var(--text-primary);
    border: 1px solid var(--border-color);
  }
</style>
