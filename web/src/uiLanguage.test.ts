/// <reference types="node" />

import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

const htmlEntries = [
  'index.html',
  'alerts.html',
  'fake-elder.html',
]

const userFacingSources = [
  ...htmlEntries,
  'src/App.tsx',
  'src/AnnotationSurface.tsx',
  'src/AlertsPage.tsx',
  'src/fake-elder.ts',
  'src/api.ts',
]

describe('English-only Web UI', () => {
  it('declares English on every built HTML entry', () => {
    for (const entry of htmlEntries) {
      expect(read(entry), entry).toMatch(/<html lang="en">/)
    }
  })

  it('contains no hard-coded Han characters in user-facing Web sources', () => {
    for (const source of userFacingSources) {
      expect(read(source), source).not.toMatch(/\p{Script=Han}/u)
    }
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
