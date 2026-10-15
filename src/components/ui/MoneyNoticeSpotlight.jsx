import React from 'react';
import Spotlight from './Spotlight';
import MoneySpotlightArt from './spotlight/MoneySpotlightArt';

export const MONEY_SPOTLIGHT_ID = 'money-model-v1';

// The "clearer money figures" notice. The caller decides whether to show it (role, dismissal, priority); `onSee` handles the button.
const MoneyNoticeSpotlight = ({ onSee, onDismiss }) => (
  <Spotlight
    id={MONEY_SPOTLIGHT_ID}
    eyebrow="Update · Money figures"
    title="Clearer money figures in ClinicMD"
    body="Owed now means visits that happened and aren't fully paid. Upcoming bookings are shown for information and no longer count as debt, so totals may look lower. No money is missing."
    primary={{ label: 'See Needs closing', onClick: onSee }}
    art={<MoneySpotlightArt />}
    onDismiss={onDismiss}
  />
);

export default MoneyNoticeSpotlight;
