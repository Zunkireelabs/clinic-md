import React from 'react';

// The ClinicMD wordmark ("Clinic" + superscript "MD"), matching the marketing site. One component so every screen shows the
// same brand mark. `size` scales the whole mark: sm ≈ sidebar/headers, md ≈ loading screens, lg ≈ hero/login.
const SIZES = {
  sm: { word: 'text-[20px]', sup: 'text-[9px]' },
  md: { word: 'text-[26px]', sup: 'text-[11px]' },
  lg: { word: 'text-[34px]', sup: 'text-[14px]' },
};

const BrandWordmark = ({ size = 'sm', className = '' }) => {
  const s = SIZES[size] || SIZES.sm;
  return (
    <span role="img" aria-label="ClinicMD" className={`inline-flex items-start text-gray-900 ${className}`}>
      <span aria-hidden="true" className={`${s.word} font-normal tracking-[-0.04em] leading-none`}>Clinic</span>
      <span aria-hidden="true" className={`${s.sup} font-medium leading-none ml-px`}>MD</span>
    </span>
  );
};

export default BrandWordmark;
