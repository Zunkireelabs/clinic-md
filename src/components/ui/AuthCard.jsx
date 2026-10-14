import React from 'react';
import BrandWordmark from './BrandWordmark';

// Shared shell for the sign-in / sign-up pages (staff login, patient login, patient sign-up): a quiet page, one centred card with the
// wordmark, a title and a subtitle, and optional content below the card. Inputs and buttons share one style (see the exports below).
export const authInputClass = (hasError = false) =>
  `w-full h-11 px-3.5 text-sm bg-surface border rounded-spa-lg text-text-primary placeholder:text-text-tertiary outline-none transition-all duration-150 focus:border-primary focus:ring-2 focus:ring-primary/20 disabled:bg-background disabled:cursor-not-allowed ${
    hasError ? 'border-error' : 'border-border'
  }`;

export const authButtonClass =
  'w-full h-11 px-5 bg-primary text-primary-foreground rounded-spa-lg text-sm font-medium hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed';

export const authSecondaryButtonClass =
  'w-full h-11 flex items-center justify-center gap-3 px-5 bg-surface border border-border rounded-spa-lg text-sm font-medium text-text-primary hover:bg-background transition-colors disabled:opacity-50 disabled:cursor-not-allowed';

export const AuthError = ({ children }) => (
  <div role="alert" className="mb-4 p-3 bg-error/10 text-error rounded-spa-lg text-sm font-medium">{children}</div>
);

export const AuthDivider = () => (
  <div className="flex items-center my-5">
    <div className="flex-1 h-px bg-border" />
    <span className="px-4 text-[13px] text-text-secondary font-medium">Or</span>
    <div className="flex-1 h-px bg-border" />
  </div>
);

const AuthFooter = () => (
  <footer className="flex-shrink-0 py-5 flex flex-col items-center gap-3">
    <div className="flex items-center gap-1.5 text-[13px]">
      <span className="text-text-secondary">from</span>
      <img src="/zunkireelabs-icon.png" alt="Zunkireelabs" className="w-[18px] h-[18px]" />
      <span className="font-medium text-text-primary">zunkireelabs</span>
    </div>
    <div className="flex items-center gap-6 text-xs text-text-secondary">
      <a href="#" className="hover:text-text-primary transition-colors">Terms of service</a>
      <a href="#" className="hover:text-text-primary transition-colors">Privacy policy</a>
      <span>&copy; {new Date().getFullYear()} ClinicMD</span>
    </div>
  </footer>
);

// topRight: e.g. the "Connected" pill. below: content under the card (links, demo box). showFooter: the zunkireelabs / Terms footer.
const AuthCard = ({ title, subtitle, children, below = null, topRight = null, showFooter = false }) => (
  <div className="login-page min-h-screen bg-background flex flex-col">
    <header className="flex-shrink-0 h-14 px-6 md:px-8 flex items-center justify-end">{topRight}</header>
    <main className="flex-1 flex flex-col items-center px-4 py-6 min-[420px]:py-10">
      <div className="w-full max-w-[400px] bg-surface border border-border rounded-spa-lg shadow-spa-elevated p-6 sm:p-10 max-[419px]:max-w-none max-[419px]:border-0 max-[419px]:shadow-none max-[419px]:rounded-none max-[419px]:bg-transparent max-[419px]:px-1">
        <div className="flex flex-col items-center text-center mb-7">
          <BrandWordmark size="lg" className="mb-6" />
          <h1 className="text-[22px] font-semibold text-text-primary tracking-tight">{title}</h1>
          {subtitle && <p className="mt-1.5 text-sm text-text-secondary">{subtitle}</p>}
        </div>
        {children}
      </div>
      {below && <div className="w-full max-w-[400px] mt-5">{below}</div>}
    </main>
    {showFooter && <AuthFooter />}
  </div>
);

export default AuthCard;
