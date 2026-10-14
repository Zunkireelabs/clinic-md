import React, { createContext, useContext, useState, useEffect, useRef } from 'react';
import { supabase } from '../lib/supabase';
import { identify, reset, setGroup } from '../lib/analytics';

const AuthContext = createContext(null);

export const useAuth = () => {
  const context = useContext(AuthContext);
  if (!context) {
    throw new Error('useAuth must be used within an AuthProvider');
  }
  return context;
};

/**
 * Get the dashboard path for a user based on their role and org.
 * @param {string} role - User's role (staff, manager, admin)
 * @param {string} orgSlug - Organization slug (e.g., 'bright-smile-dental')
 * @returns {string} - Dashboard path
 */
export const getDashboardPath = (role, orgSlug) => {
  // If no orgSlug provided, fall back to legacy path (for backwards compatibility during transition)
  if (!orgSlug) {
    switch (role) {
      case 'manager':
      case 'admin':
      case 'admin_viewer':
        return '/branch-manager-dashboard';
      case 'staff':
      default:
        return '/branch-staff-dashboard';
    }
  }

  // New org-scoped path - role determines the view, not the URL
  return `/${orgSlug}/dashboard`;
};

/**
 * Where to send a freshly authenticated user: the page they originally asked for, but only if it is a plain in-app path
 * inside their OWN org (`/<their-org>/...`). Anything else (another org, an absolute URL, protocol-relative `//host`,
 * the login page itself) is ignored and the caller falls back to the default dashboard.
 * @param {{pathname?: string, search?: string, hash?: string}|string|undefined} from - `location.state.from`
 * @param {string} orgSlug - the authenticated user's org slug
 * @returns {string|null}
 */
export const getSafeRedirect = (from, orgSlug) => {
  if (!from || !orgSlug) return null;
  const pathname = typeof from === 'string' ? from.split(/[?#]/)[0] : from.pathname;
  const rest = typeof from === 'string' ? from.slice(pathname.length) : `${from.search || ''}${from.hash || ''}`;
  if (typeof pathname !== 'string' || !pathname.startsWith(`/${orgSlug}/`)) return null;
  if (pathname.startsWith('//') || /[\\]|:\/\//.test(pathname + rest)) return null;
  if (/(^|\/)\.\.?(\/|$)/.test(pathname)) return null; // no dot-segments
  if (pathname === `/${orgSlug}/login`) return null;
  return `${pathname}${rest}`;
};

/**
 * Fetch a user's staff profile from public.users with branch name.
 *
 * When called with an explicit accessToken (e.g. right after signIn),
 * we use a direct REST call because the supabase-js client's internal
 * session state may not be ready yet after signInWithPassword.
 *
 * When called without a token (page refresh), the supabase client reads
 * the stored session from localStorage automatically — this path works fine.
 */
async function fetchProfile(userId, accessToken) {
  try {
    if (accessToken) {
      const url = `${import.meta.env.VITE_SUPABASE_URL}/rest/v1/users`
        + `?select=*,branches!users_branch_id_fkey(name),organizations(id,name,code,slug)&id=eq.${userId}`;
      const res = await fetch(url, {
        headers: {
          'apikey': import.meta.env.VITE_SUPABASE_ANON_KEY,
          'Authorization': `Bearer ${accessToken}`,
          'Accept': 'application/vnd.pgrst.object+json',
        },
      });
      if (!res.ok) {
        const body = await res.text();
        console.error('[Auth] Profile fetch failed:', res.status, body);
        return null;
      }
      return await res.json();
    }

    // Fallback: use supabase client (session from localStorage)
    const { data, error } = await supabase
      .from('users')
      .select('*, branches!users_branch_id_fkey(name), organizations(id, name, code, slug)')
      .eq('id', userId)
      .single();

    if (error) {
      console.error('[Auth] Profile fetch error:', error.message);
      return null;
    }
    return data;
  } catch (err) {
    console.error('[Auth] Profile fetch exception:', err);
    return null;
  }
}

export const AuthProvider = ({ children }) => {
  const [user, setUser] = useState(null);
  const [profile, setProfile] = useState(null);
  const [loading, setLoading] = useState(true);
  // True once supabase has reported the stored session (INITIAL_SESSION), so "no user yet" can be told apart from "no session".
  const [sessionResolved, setSessionResolved] = useState(false);

  // Guard: when signIn() is actively running, the useEffect must not
  // race with its own profile fetch.
  const signInActiveRef = useRef(false);

  const signIn = async (email, password) => {
    signInActiveRef.current = true;

    try {
      const { data, error } = await supabase.auth.signInWithPassword({
        email,
        password,
      });

      if (error) throw error;

      const userProfile = await fetchProfile(
        data.user.id,
        data.session.access_token
      );

      setUser(data.user);
      setProfile(userProfile);
      setLoading(false);

      if (userProfile) {
        identify(userProfile.id, {
          email: userProfile.email,
          role: userProfile.role,
          branch_id: userProfile.branch_id,
          org_slug: userProfile.organizations?.slug,
        });
        if (userProfile.org_id) {
          setGroup('organization', userProfile.org_id, {
            name: userProfile.organizations?.name,
            slug: userProfile.organizations?.slug,
          });
        }
      }

      return { user: data.user, profile: userProfile };
    } finally {
      signInActiveRef.current = false;
    }
  };

  const signOut = async () => {
    reset();
    setProfile(null);
    setUser(null);
    const { error } = await supabase.auth.signOut();
    if (error) console.error('[Auth] Sign out error:', error.message);
  };

  // Bootstrap: listen for auth state changes.
  // The callback MUST stay synchronous — supabase-js awaits all listeners
  // inside signInWithPassword, so any await here would deadlock.
  useEffect(() => {
    const { data: { subscription } } = supabase.auth.onAuthStateChange(
      (event, session) => {
        // During signIn(), we handle user + profile ourselves.
        // Only update state from the listener when signIn is NOT active.
        if (signInActiveRef.current) return;

        setSessionResolved(true);
        if (session?.user) {
          setUser(session.user);
        } else {
          setUser(null);
          setProfile(null);
        }

        if (event === 'INITIAL_SESSION' && !session?.user) {
          setLoading(false);
        }
      }
    );

    return () => subscription.unsubscribe();
  }, []);

  // Fetch profile on page refresh (INITIAL_SESSION with an existing session).
  // Skipped when signIn already set both user + profile in the same render.
  useEffect(() => {
    let cancelled = false;

    if (!user) {
      // Until the stored session has been reported there is simply no user *yet*; staying in `loading` stops ProtectedRoute
      // from bouncing a signed-in user (hard reload / deep link) through /login before their session has been restored.
      if (sessionResolved) setLoading(false);
      return;
    }

    // signIn() is handling auth + profile — don't compete
    if (signInActiveRef.current) return;

    // Profile already loaded for this user
    if (profile && profile.id === user.id) {
      setLoading(false);
      return;
    }

    setLoading(true);

    // No explicit token — supabase client uses localStorage session
    fetchProfile(user.id)
      .then((p) => { if (!cancelled) setProfile(p); })
      .finally(() => { if (!cancelled) setLoading(false); });

    return () => { cancelled = true; };
  }, [user?.id, sessionResolved]);

  return (
    <AuthContext.Provider value={{ user, profile, loading, signIn, signOut }}>
      {children}
    </AuthContext.Provider>
  );
};
