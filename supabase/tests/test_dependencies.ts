import type { EdgeDependencies } from '../functions/_shared/handler.ts'

type DependencyOverrides = {
  sessions?: Partial<EdgeDependencies['sessions']>
  events?: Partial<EdgeDependencies['events']>
  alerts?: Partial<EdgeDependencies['alerts']>
  tokens?: Partial<EdgeDependencies['tokens']>
  ai?: Partial<EdgeDependencies['ai']>
  publicLiveKitUrl?: string
  makeCode?: () => string
}

export function makeTestDependencies(overrides: DependencyOverrides = {}): EdgeDependencies {
  const unexpected = (name: string): never => {
    throw new Error(`Unexpected dependency call: ${name}`)
  }
  const defaults: EdgeDependencies = {
    sessions: {
      async create() {
        return unexpected('sessions.create')
      },
      async findByCode() {
        return unexpected('sessions.findByCode')
      },
      async activate() {
        return unexpected('sessions.activate')
      },
      async freeze() {
        return unexpected('sessions.freeze')
      },
    },
    events: {
      async insert() {
        return unexpected('events.insert')
      },
    },
    alerts: {
      async insert() {
        return unexpected('alerts.insert')
      },
    },
    tokens: {
      async sign() {
        return unexpected('tokens.sign')
      },
    },
    ai: {
      async guide() {
        return unexpected('ai.guide')
      },
      async referee() {
        return unexpected('ai.referee')
      },
    },
    publicLiveKitUrl: 'wss://demo.livekit.cloud',
    makeCode: () => unexpected('makeCode'),
  }

  return {
    ...defaults,
    ...overrides,
    sessions: { ...defaults.sessions, ...overrides.sessions },
    events: { ...defaults.events, ...overrides.events },
    alerts: { ...defaults.alerts, ...overrides.alerts },
    tokens: { ...defaults.tokens, ...overrides.tokens },
    ai: { ...defaults.ai, ...overrides.ai },
  }
}
