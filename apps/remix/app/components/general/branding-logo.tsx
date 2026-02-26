import type { ImgHTMLAttributes } from 'react';

export type LogoProps = ImgHTMLAttributes<HTMLImageElement>;

export const BrandingLogo = ({ className, ...props }: LogoProps) => {
  return (
    <img
      src="/static/aline-docsign-logo.jpg"
      alt="Aline Docsign"
      className={className}
      {...props}
    />
  );
};
