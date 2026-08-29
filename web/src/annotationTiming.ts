export function opacityForExpiry(expiresAt: number, now: number): number {
  return Math.max(0, Math.min(1, (expiresAt - now) / 600))
}
