export function shouldSendPointer(lastSentAt: number, now: number): boolean {
  return now - lastSentAt >= 30
}
