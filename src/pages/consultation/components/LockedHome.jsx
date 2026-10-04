import React from 'react';
import Icon from '../../../components/AppIcon';

// What the Doctor app shows when it is opened with no work started: nothing about any
// patient. When a consultation starts on the computer, the phone is told, and the code
// is asked for then. The doctor can also ask for a code on purpose with the button.
const LockedHome = ({ onAsk }) => (
  <div className="min-h-screen bg-background flex items-center justify-center p-6">
    <div className="w-full max-w-sm text-center space-y-5">
      <div className="mx-auto w-16 h-16 rounded-full bg-primary/10 flex items-center justify-center">
        <Icon name="Smartphone" size={28} className="text-primary" />
      </div>
      <div>
        <h1 className="font-heading font-heading-semibold text-xl text-text-primary">Doctor app</h1>
        <p className="text-sm text-text-secondary mt-1 flex items-center justify-center gap-2">
          <span className="w-2 h-2 rounded-full bg-success animate-pulse" /> Waiting for a consultation to start
        </p>
      </div>
      <p className="text-xs text-text-tertiary px-2">
        When a consultation starts on the computer, this phone is notified and a code appears on the computer. Type it here to open the patient.
      </p>
      <button type="button" onClick={onAsk} className="text-sm text-primary font-medium">
        Need in without a new consultation? Ask the computer for a code
      </button>
    </div>
  </div>
);

export default LockedHome;
