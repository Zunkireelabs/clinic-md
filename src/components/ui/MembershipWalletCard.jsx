import React from 'react';
import Icon from '../AppIcon';

const MEMBERSHIP_STATUS_STYLES = {
  // Neutral hairline card; amber (the Pending tone) only for states that need attention.
  active:   { container: 'bg-background border-border',       pill: 'bg-gray-100 text-text-secondary', label: 'Active' },
  pending:  { container: 'bg-background border-border',       pill: 'bg-[#FBF5E6] text-[#7A5408]',     label: 'Pending' },
  lapsed:   { container: 'bg-background border-border',       pill: 'bg-[#FBF5E6] text-[#7A5408]',     label: 'Lapsed' },
  depleted: { container: 'bg-background border-border',       pill: 'bg-gray-100 text-text-secondary', label: 'Depleted' },
};

function formatNPR(amount) {
  return `NPR ${Number(amount).toLocaleString('en-IN')}`;
}

// Membership wallet banner — tier, membership number, status, current balance.
// `paidThisVisit` is optional: when provided (>0), shows how much of the
// currently-open booking was drawn from the wallet, alongside the balance,
// which the DB already keeps live/up to date after every deduction.
// `pendingDeduction` is optional: when provided (>0) — e.g. a Membership tender
// currently entered but not yet confirmed — shows a live "after this payment"
// projection right in the card, instead of only as a small caption elsewhere.
const MembershipWalletCard = ({ membership, paidThisVisit = 0, pendingDeduction = 0 }) => {
  if (!membership) return null;

  const styleKey = membership.status || 'pending';
  const styles = MEMBERSHIP_STATUS_STYLES[styleKey] || MEMBERSHIP_STATUS_STYLES.pending;
  const projectedBalance = Math.max(Number(membership.balance) - pendingDeduction, 0);

  return (
    <div className={`rounded-spa border ${styles.container} px-3 py-2.5`}>
      <div className="flex items-center justify-between">
        <div className="flex items-center space-x-2 min-w-0">
          <Icon name="Wallet" size={14} className="text-primary flex-shrink-0" />
          <span className="font-body font-body-medium text-sm text-text-primary truncate">{membership.tierName}</span>
          {membership.membershipNumber && (
            <span className="font-data font-data-medium text-[11px] tracking-widest text-text-secondary">{membership.membershipNumber}</span>
          )}
          <span className={`inline-flex items-center space-x-1 px-1.5 py-0.5 rounded-full text-[10px] font-caption font-caption-medium ${styles.pill}`}>
            {styles.label}
          </span>
        </div>
        <div className="flex items-center gap-1.5 flex-shrink-0">
          <span className={`font-data font-data-medium text-sm text-primary ${pendingDeduction > 0 ? 'line-through text-text-tertiary' : ''}`}>
            {formatNPR(membership.balance)}
          </span>
          {pendingDeduction > 0 && (
            <>
              <Icon name="ArrowRight" size={12} className="text-text-secondary" />
              <span className="font-data font-data-medium text-sm text-primary">{formatNPR(projectedBalance)}</span>
            </>
          )}
        </div>
      </div>
      {pendingDeduction > 0 && (
        <p className="mt-1.5 font-caption text-[11px] text-text-secondary">
          Left after this payment: {formatNPR(projectedBalance)}
        </p>
      )}
      {paidThisVisit > 0 && (
        <p className="mt-1.5 font-caption text-[11px] text-text-secondary">
          Paid from wallet for this visit: {formatNPR(paidThisVisit)}
        </p>
      )}
      {membership.status === 'lapsed' && (
        <p className="mt-1.5 font-caption text-[11px] text-[#7A5408]">
          Membership expired on {membership.expiryDate || '—'}. Wallet balance is still spendable but
          discount privileges no longer apply.
        </p>
      )}
      {membership.status === 'pending' && (
        <p className="mt-1.5 font-caption text-[11px] text-[#7A5408]">
          Pending activation — wallet is not yet usable for booking payments. Top up to NPR {Number(membership.tierAdvanceAmount).toLocaleString('en-IN')} to activate.
        </p>
      )}
      {membership.status === 'depleted' && (
        <p className="mt-1.5 font-caption text-[11px] text-text-tertiary">
          Wallet is depleted.
        </p>
      )}
    </div>
  );
};

export default MembershipWalletCard;
