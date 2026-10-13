import React, { useState, useRef, useCallback } from 'react';
import { useNavigate } from 'react-router-dom';
import Icon from '../AppIcon';
import { useAuth } from 'contexts/AuthContext';
import { useBranch } from 'contexts/BranchContext';
import { useMenuNav } from './useMenuNav';

const ROLE_LABELS = {
  admin: 'Admin',
  admin_viewer: 'Admin (view only)',
  manager: 'Branch Manager',
  staff: 'Staff',
};

const getInitials = (name = '') => {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return '?';
  return (parts[0][0] + (parts.length > 1 ? parts[parts.length - 1][0] : '')).toUpperCase();
};

const Avatar = ({ name, src }) => {
  const [broken, setBroken] = useState(false);
  return (
    <span className={`w-8 h-8 text-xs rounded-full overflow-hidden bg-primary/10 text-primary flex items-center justify-center flex-shrink-0 font-body font-body-medium`}>
      {src && !broken ? (
        <img src={src} alt="" className="w-full h-full object-cover" onError={() => setBroken(true)} />
      ) : (
        getInitials(name)
      )}
    </span>
  );
};

const ProfileMenu = () => {
  const { profile, signOut } = useAuth();
  const { isOverall } = useBranch();
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);
  const menuRef = useRef(null);
  const triggerRef = useRef(null);
  const close = useCallback(() => setOpen(false), []);
  useMenuNav({ open, onClose: close, menuRef, triggerRef });

  const role = profile?.role;
  const name = profile?.full_name || 'Account';
  const email = profile?.email || '';
  const org = profile?.organizations?.name;
  const roleLine = [ROLE_LABELS[role] || 'Staff', org].filter(Boolean).join(' · ');

  // There is no account/settings page; "Settings" opens the Setup area (manager/admin only).
  // Overall is read-only and hides the write views, so it lands on the Audit Log instead.
  const canSettings = role === 'manager' || role === 'admin' || role === 'admin_viewer';
  // The calendar owns the shortcuts help and toggles it on "?"; only offer the item there.
  const onCalendar = new URLSearchParams(window.location.search).get('view') === 'calendar';

  const run = (fn) => () => {
    setOpen(false);
    fn();
  };
  const openSettings = () => navigate(isOverall ? '?view=audit' : '?view=treatments');
  const openShortcuts = () => setTimeout(() => document.dispatchEvent(new KeyboardEvent('keydown', { key: '?' })), 0);

  const row = 'w-full h-9 flex items-center gap-3 px-2.5 rounded-spa text-left text-sm font-body text-text-primary hover:bg-black/[0.04] focus:bg-black/[0.04] focus:outline-none';

  return (
    <div className="relative flex flex-shrink-0">
      <button
        ref={triggerRef}
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label="Account menu"
        className={`rounded-full ring-2 ring-offset-0 focus:outline-none focus-visible:ring-primary ${open ? 'ring-primary' : 'ring-transparent'}`}
      >
        <Avatar name={name} src={profile?.avatar_url} />
      </button>
      {open && (
        <div
          ref={menuRef}
          role="menu"
          aria-label="Account"
          className="absolute right-0 top-[calc(50%+34px)] w-64 bg-surface border border-border rounded-xl shadow-spa-elevated z-dropdown p-1.5"
        >
          <div className="p-3 mb-1 rounded-spa-lg bg-background">
            <div className="min-w-0">
              <p className="text-sm font-semibold text-text-primary truncate">{name}</p>
              {email && <p className="text-[13px] text-text-secondary truncate">{email}</p>}
              <p className="text-xs text-text-tertiary truncate" title={roleLine}>{roleLine}</p>
            </div>
          </div>
          {canSettings && (
            <button type="button" role="menuitem" className={row} onClick={run(openSettings)}>
              <Icon name="Settings" size={16} className="text-text-tertiary" />
              <span className="flex-1">Settings</span>
            </button>
          )}
          {onCalendar && (
            <button type="button" role="menuitem" className={row} onClick={run(openShortcuts)}>
              <Icon name="Keyboard" size={16} className="text-text-tertiary" />
              <span className="flex-1">Keyboard shortcuts</span>
              <kbd className="text-xs text-text-tertiary font-body">?</kbd>
            </button>
          )}
          <div className="my-1.5 h-px bg-border" />
          <button type="button" role="menuitem" className={row} onClick={run(() => signOut())}>
            <Icon name="LogOut" size={16} className="text-text-tertiary" />
            <span className="flex-1">Sign out</span>
          </button>
        </div>
      )}
    </div>
  );
};

export default ProfileMenu;
