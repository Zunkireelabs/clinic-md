import React, { useState, useRef, useEffect, useCallback } from 'react';
import Icon from '../AppIcon';
import { searchCustomers } from 'services/api';

// Color tokens for the inline membership pill (mirrors MembershipsPanel).
const MEMBERSHIP_PILL_STYLES = {
  active:   'bg-success/10 text-success',
  lapsed:   'bg-warning/10 text-warning',
  pending:  'bg-amber-100 text-amber-800',
  depleted: 'bg-gray-100 text-gray-600',
};

const CustomerAutocomplete = ({
  value,
  onChange,
  onSelect,
  branchId,
  searchBy = 'name',
  placeholder = searchBy === 'phone' ? '98XXXXXXXX' : searchBy === 'email' ? 'Enter customer email' : 'Enter customer name',
  inputClassName,
  inputRef: externalRef,
  onBlur,
  required = false,
}) => {
  const [suggestions, setSuggestions] = useState([]);
  const [showSuggestions, setShowSuggestions] = useState(false);
  const [focusedIndex, setFocusedIndex] = useState(-1);
  const containerRef = useRef(null);
  const listRef = useRef(null);
  const internalRef = useRef(null);
  const ref = externalRef || internalRef;

  // Bounded server-side search as the user types (>= 2 chars, ~200ms debounce, 8 results). A request id drops responses that are
  // older than the latest query; there is no whole-list fetch on mount. Matches the field's `searchBy` (name / phone / email).
  const reqIdRef = useRef(0);
  useEffect(() => {
    const term = (value || '').trim();
    const id = ++reqIdRef.current;
    if (!branchId || term.length < 2) { setSuggestions([]); return undefined; }
    const timer = setTimeout(async () => {
      const { data, error } = await searchCustomers(branchId, term, 8, { searchBy, withMembership: true });
      if (id !== reqIdRef.current) return; // stale
      if (error) { console.error('[CustomerAutocomplete] Search failed:', error.message || error); return; }
      setSuggestions(data || []);
    }, 200);
    return () => clearTimeout(timer);
  }, [value, branchId, searchBy]);

  // Show/hide suggestions based on matches
  useEffect(() => {
    setShowSuggestions(suggestions.length > 0);
    setFocusedIndex(-1);
  }, [suggestions]);

  // Close on click outside
  useEffect(() => {
    const handleClickOutside = (e) => {
      if (containerRef.current && !containerRef.current.contains(e.target)) {
        setShowSuggestions(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  // Scroll focused item into view
  useEffect(() => {
    if (listRef.current && focusedIndex >= 0) {
      const items = listRef.current.children;
      if (items[focusedIndex]) {
        items[focusedIndex].scrollIntoView({ block: 'nearest' });
      }
    }
  }, [focusedIndex]);

  const handleSelectCustomer = useCallback((customer) => {
    onSelect(customer);
    setShowSuggestions(false);
  }, [onSelect]);

  const handleKeyDown = (e) => {
    if (!showSuggestions) return;

    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault();
        setFocusedIndex((prev) => Math.min(prev + 1, suggestions.length - 1));
        break;
      case 'ArrowUp':
        e.preventDefault();
        setFocusedIndex((prev) => Math.max(prev - 1, 0));
        break;
      case 'Enter':
        if (focusedIndex >= 0 && focusedIndex < suggestions.length) {
          e.preventDefault();
          handleSelectCustomer(suggestions[focusedIndex]);
        }
        break;
      case 'Escape':
        setShowSuggestions(false);
        break;
      default:
        break;
    }
  };

  return (
    <div ref={containerRef} className="relative">
      <input
        ref={ref}
        type="text"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={handleKeyDown}
        onFocus={() => { if (suggestions.length > 0) setShowSuggestions(true); }}
        onBlur={onBlur}
        required={required}
        placeholder={placeholder}
        className={inputClassName || "w-full px-3 py-2 text-sm border border-border rounded-spa bg-surface text-text-primary placeholder:text-text-secondary/50 focus:outline-none focus:ring-2 focus:ring-primary/30 focus:border-primary"}
      />

      {showSuggestions && (
        <div
          ref={listRef}
          className="absolute left-0 top-full mt-1 w-full bg-white border border-gray-200 rounded-md shadow-lg z-50 py-1 max-h-48 overflow-y-auto"
        >
          {suggestions.map((customer, index) => {
            const m = customer.primaryMembership;
            const pillClass = m ? (MEMBERSHIP_PILL_STYLES[m.status] || MEMBERSHIP_PILL_STYLES.pending) : '';
            return (
              <button
                key={customer.id}
                type="button"
                onClick={() => handleSelectCustomer(customer)}
                onMouseEnter={() => setFocusedIndex(index)}
                className={`w-full text-left px-3 py-2 text-sm flex items-center justify-between gap-2 ${
                  focusedIndex === index ? 'bg-gray-100' : ''
                } hover:bg-gray-50`}
              >
                <span className="flex-1 min-w-0 truncate">
                  <span className="font-medium text-text-primary">{customer.full_name}</span>
                  {customer.phone && (
                    <span className="ml-2 text-text-secondary">{customer.phone}</span>
                  )}
                </span>
                {m && (
                  <span
                    title={[m.tierName, m.membershipNumber, m.status !== 'active' ? m.status : null].filter(Boolean).join(' · ')}
                    className={`flex-shrink-0 max-w-[6.5rem] truncate inline-flex items-center px-1.5 py-0.5 rounded-full text-[10px] font-medium tracking-wide ${pillClass}`}
                  >
                    {m.tierName || m.membershipNumber}
                    {m.status !== 'active' && ` · ${m.status}`}
                  </span>
                )}
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
};

export default CustomerAutocomplete;
