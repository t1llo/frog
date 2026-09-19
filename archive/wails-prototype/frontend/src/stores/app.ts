import { writable } from 'svelte/store';

// Navigation
export type View = 'text' | 'models' | 'shortcuts' | 'settings';
export const currentView = writable<View>('text');

// Processing state
export const isProcessing = writable(false);
export const processingError = writable<string | null>(null);

// Notification
export interface Notification {
  message: string;
  type: 'success' | 'error' | 'info';
}
export const notification = writable<Notification | null>(null);

export function showNotification(message: string, type: 'success' | 'error' | 'info' = 'info') {
  notification.set({ message, type });
  setTimeout(() => notification.set(null), 3000);
}
