import React, { useState, useEffect, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import Icon from '../AppIcon';
import BranchSwitcher from './BranchSwitcher';
import NotificationBell from './NotificationBell';
import { useAuth } from '../../contexts/AuthContext';
import { useAIAssistant } from '../../contexts/AIAssistantContext';
import { usePersistentNotifications } from '../../hooks/usePersistentNotifications';

/**
 * Top bar for staff pages outside the dashboards (branch switcher, clock,
 * status, assistant, notifications, profile) so they match the dashboard header.
 */
const StaffTopBar = ({ orgSlug }) => {
  const navigate = useNavigate();
  const { profile, signOut, user } = useAuth();
  const { isOpen: isAssistantOpen, toggleAssistant } = useAIAssistant();
  const { items, markRead, markAllRead } = usePersistentNotifications(user?.id);

  const [now, setNow] = useState(new Date());
  const [online, setOnline] = useState(typeof navigator === 'undefined' ? true : navigator.onLine);
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef(null);

  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), 30000);
    return () => clearInterval(t);
  }, []);

  useEffect(() => {
    const up = () => setOnline(true);
    const down = () => setOnline(false);
    window.addEventListener('online', up);
    window.addEventListener('offline', down);
    return () => {
      window.removeEventListener('online', up);
      window.removeEventListener('offline', down);
    };
  }, []);

  useEffect(() => {
    if (!menuOpen) return undefined;
    const onDown = (e) => { if (menuRef.current && !menuRef.current.contains(e.target)) setMenuOpen(false); };
    document.addEventListener('mousedown', onDown);
    return () => document.removeEventListener('mousedown', onDown);
  }, [menuOpen]);

  const name = profile?.full_name || 'Staff';
  const role = profile?.role || 'staff';
  const isAdmin = role === 'admin';
  const unread = items.filter((n) => !n.read).length;

  const handleNotificationClick = (n) => {
    markRead(n.id);
    if (orgSlug) navigate(`/${orgSlug}/dashboard?view=bookings`);
  };

  return (
    <header className="bg-surface-sidebar sticky top-0 z-header flex-shrink-0">
      <div className="px-4 sm:px-6 lg:px-8 py-3 flex items-center justify-between">
        <div className="flex items-center space-x-3 min-w-0">
          <BranchSwitcher />
          <div className="hidden sm:block h-5 w-px bg-border" />
          <p className="hidden sm:block font-caption text-xs text-text-secondary">
            {now.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' })} {'·'}{' '}
            {now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
          </p>
        </div>

        <div className="flex items-center space-x-3 flex-shrink-0 ml-3">
          <div
            className="hidden sm:flex items-center space-x-1.5 px-2 py-1 rounded-full bg-background border border-border"
            title={online ? 'Connected' : 'No internet connection'}
          >
            <span className={`inline-flex rounded-full h-2 w-2 ${online ? 'bg-success' : 'bg-error'}`} />
            <span className="text-xs font-caption font-caption-medium text-text-secondary">{online ? 'Live' : 'Offline'}</span>
          </div>

          <span className={`hidden sm:inline-flex items-center px-2 py-0.5 rounded text-xs font-caption capitalize ${
            isAdmin ? 'bg-pink-100 text-pink-700' : 'bg-accent/10 text-accent'
          }`}>
            {role.replace('_', ' ')}
          </span>

          <button
            type="button"
            onClick={toggleAssistant}
            className={`flex items-center gap-2 px-3 py-2 rounded-lg transition-all ${
              isAssistantOpen ? 'bg-gradient-to-r from-purple-500 to-pink-500 text-white shadow-md' : 'hover:bg-gray-100 text-gray-700'
            }`}
          >
            <Icon name="Sparkles" size={16} className={isAssistantOpen ? 'text-white' : 'text-purple-500'} />
            <span className="text-sm font-medium hidden sm:inline">Assistant</span>
          </button>

          <NotificationBell
            notifications={items}
            unreadCount={unread}
            onMarkAllRead={markAllRead}
            onItemClick={handleNotificationClick}
          />

          <div className="relative" ref={menuRef}>
            <button
              type="button"
              onClick={() => setMenuOpen((v) => !v)}
              className="flex items-center space-x-2 px-2 py-1 rounded-spa hover:bg-background spa-transition-fast"
            >
              <div className="w-8 h-8 rounded-full bg-primary/10 text-primary flex items-center justify-center text-sm font-medium">
                {name.trim().charAt(0).toUpperCase()}
              </div>
              <div className="hidden md:flex flex-col text-left">
                <span className="font-body font-body-medium text-sm text-text-primary leading-tight">{name}</span>
                <span className="font-caption text-xs text-text-secondary capitalize leading-tight">{role.replace('_', ' ')}</span>
              </div>
              <Icon name="ChevronDown" size={16} className={`text-gray-400 transition-transform ${menuOpen ? 'rotate-180' : ''}`} />
            </button>
            {menuOpen && (
              <div className="absolute right-0 top-full mt-3 w-64 bg-white rounded-xl shadow-lg border border-gray-200 py-2 z-dropdown">
                <div className="px-4 py-3 border-b border-gray-100">
                  <p className="text-sm font-semibold text-gray-900 truncate">{name}</p>
                  {profile?.email && <p className="text-xs text-gray-500 truncate">{profile.email}</p>}
                </div>
                <button
                  type="button"
                  onClick={() => { setMenuOpen(false); signOut(); }}
                  className="w-full flex items-center gap-3 px-4 py-2.5 text-sm text-red-600 hover:bg-red-50 transition-colors"
                >
                  <Icon name="LogOut" size={16} />
                  <span>Logout</span>
                </button>
              </div>
            )}
          </div>
        </div>
      </div>
    </header>
  );
};

export default StaffTopBar;
