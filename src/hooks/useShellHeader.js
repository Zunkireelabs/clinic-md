import { useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '../contexts/AuthContext';
import { useAIAssistant } from '../contexts/AIAssistantContext';
import { usePersistentNotifications } from './usePersistentNotifications';

// Props for <AppShell header={…}> on pages that are not one of the two dashboards (the consultation page, the patient chart):
// connection status from the browser's online state, persistent notifications, and the Assistant toggle.
export const useShellHeader = (orgSlug) => {
  const navigate = useNavigate();
  const { user } = useAuth();
  const { isOpen: assistantOpen, toggleAssistant } = useAIAssistant();
  const { items, markRead, markAllRead } = usePersistentNotifications(user?.id);
  const [online, setOnline] = useState(typeof navigator === 'undefined' ? true : navigator.onLine);

  useEffect(() => {
    const up = () => setOnline(true);
    const down = () => setOnline(false);
    window.addEventListener('online', up);
    window.addEventListener('offline', down);
    return () => { window.removeEventListener('online', up); window.removeEventListener('offline', down); };
  }, []);

  return {
    assistantOpen,
    header: {
      realtimeStatus: online ? 'connected' : 'disconnected',
      onToggleAssistant: toggleAssistant,
      assistantOpen,
      notifications: items,
      unreadCount: items.filter((n) => !n.read).length,
      onMarkAllRead: markAllRead,
      onItemClick: (n) => { markRead(n.id); if (orgSlug) navigate(`/${orgSlug}/dashboard?view=bookings`); },
    },
  };
};
