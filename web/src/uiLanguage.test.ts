/// <reference types="node" />

import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { messages } from './i18n'

const htmlEntries = [
  'index.html',
  'alerts.html',
  'fake-elder.html',
]

describe('bilingual Web UI', () => {
  it('declares an English fallback on every built HTML entry', () => {
    for (const entry of htmlEntries) {
      expect(read(entry), entry).toMatch(/<html lang="en">/)
    }
  })

  it('provides a non-empty English and Chinese version for every message', () => {
    for (const [key, value] of Object.entries(messages)) {
      expect(value.en.trim(), `${key}.en`).not.toBe('')
      expect(value.zh.trim(), `${key}.zh`).not.toBe('')
    }
  })

  it('uses one shared button height across the Web UI', () => {
    const globalStyles = read('src/index.css')
    expect(globalStyles).toContain('--button-height: 46px;')
    expect(globalStyles).toMatch(/button\s*\{[^}]*height:\s*var\(--button-height\);/s)
    expect(read('src/App.css')).not.toMatch(/(?:^|\n)[^@\n][^{]*button[^}]*\bheight:\s*\d+px;/s)
  })

  it('keeps the document usable on a 320px-wide viewport', () => {
    const globalStyles = read('src/index.css')
    const mobileStyles = read('src/App.css').split('@media (max-width: 760px)').at(-1) ?? ''

    expect(globalStyles).not.toMatch(/min-width:\s*(?:[4-9]\d{2}|\d{4,})px/)
    expect(mobileStyles).toContain('grid-template-columns: repeat(2, minmax(0, 1fr));')
    expect(mobileStyles).toMatch(/\.annotation-toolbar button\s*\{[^}]*min-width:\s*0;/s)
  })
})

function read(path: string): string {
  return readFileSync(resolve(process.cwd(), path), 'utf8')
}
