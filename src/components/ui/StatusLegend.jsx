import React from 'react';
import { BOOKING_STATUS_COLORS, UNPAID_DOT_COLOR } from '../../utils/bookingStatusColors';

const STATUS_ITEMS = [
  { key: 'pending', label: 'Pending', color: BOOKING_STATUS_COLORS['Pending'].bar },
  { key: 'confirmed', label: 'Confirmed', color: BOOKING_STATUS_COLORS['Confirmed'].bar },
  { key: 'in-progress', label: 'In Progress', color: BOOKING_STATUS_COLORS['In-Progress'].bar },
  { key: 'completed', label: 'Completed', color: BOOKING_STATUS_COLORS['Completed'].bar },
  { key: 'cancelled', label: 'Cancelled', color: BOOKING_STATUS_COLORS['Cancelled'].bar },
  { key: 'no show', label: 'No Show', color: BOOKING_STATUS_COLORS['No Show'].bar },
];

const PAYMENT_ITEMS = [
  { key: 'unpaid', label: 'Unpaid', borderColor: UNPAID_DOT_COLOR },
];

const StatusLegend = ({ showPayment = false, compact = false }) => {
  return (
    <div className={`flex items-center flex-wrap ${compact ? 'gap-x-3 gap-y-1' : 'gap-x-4 gap-y-1'}`}>
      {STATUS_ITEMS.map((item) => (
        <div key={item.key} className="flex items-center space-x-1.5">
          <span
            className="inline-block w-2.5 h-2.5 rounded-sm"
            style={{ backgroundColor: item.color }}
          />
          <span className="font-caption font-caption-normal text-xs text-text-secondary">
            {item.label}
          </span>
        </div>
      ))}
      {showPayment && PAYMENT_ITEMS.map((item) => (
        <div key={item.key} className="flex items-center space-x-1.5">
          <span
            className="inline-block w-2.5 h-2.5 rounded-sm border-2"
            style={{ borderColor: item.borderColor, backgroundColor: 'transparent' }}
          />
          <span className="font-caption font-caption-normal text-xs text-text-secondary">
            {item.label}
          </span>
        </div>
      ))}
    </div>
  );
};

export default StatusLegend;
