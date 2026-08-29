import type { EdgeDependencies } from '../functions/_shared/handler.ts'

type DependencyOverrides = {
  sessions?: Partial<EdgeDependencies['sessions']>
  events?: Partial<EdgeDependencies['events']>
  alerts?: Partial<EdgeDependencies['alerts']>
  assistants?: Partial<EdgeDependencies['assistants']>
  broadcasts?: Partial<EdgeDependencies['broadcasts']>
  tokens?: Partial<EdgeDependencies['tokens']>
  elderCredentials?: Partial<EdgeDependencies['elderCredentials']>
  assemblyAI?: Partial<EdgeDependencies['assemblyAI']>
  ai?: Partial<EdgeDependencies['ai']>
  publicLiveKitUrl?: string
  makeCode?: () => string
  now?: () => Date
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
      async findById() {
        return unexpected('sessions.findById')
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
      async list() {
        return unexpected('alerts.list')
      },
    },
    assistants: {
      async touch() {
        return unexpected('assistants.touch')
      },
      async countSince() {
        return unexpected('assistants.countSince')
      },
    },
    broadcasts: {
      async setActive() {
        return unexpected('broadcasts.setActive')
      },
      async listActive() {
        return unexpected('broadcasts.listActive')
      },
      async findClaimable() {
        return unexpected('broadcasts.findClaimable')
      },
      async claim() {
        return unexpected('broadcasts.claim')
      },
    },
    tokens: {
      async sign() {
        return unexpected('tokens.sign')
      },
    },
    elderCredentials: {
      async verify() {
        return unexpected('elderCredentials.verify')
      },
    },
    assemblyAI: {
      async createStreamingToken() {
        return unexpected('assemblyAI.createStreamingToken')
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
    now: () => new Date('2026-08-29T10:00:00.000Z'),
  }

  return {
    ...defaults,
    ...overrides,
    sessions: { ...defaults.sessions, ...overrides.sessions },
    events: { ...defaults.events, ...overrides.events },
    alerts: { ...defaults.alerts, ...overrides.alerts },
    assistants: { ...defaults.assistants, ...overrides.assistants },
    broadcasts: { ...defaults.broadcasts, ...overrides.broadcasts },
    tokens: { ...defaults.tokens, ...overrides.tokens },
    elderCredentials: { ...defaults.elderCredentials, ...overrides.elderCredentials },
    assemblyAI: { ...defaults.assemblyAI, ...overrides.assemblyAI },
    ai: { ...defaults.ai, ...overrides.ai },
  }
}
