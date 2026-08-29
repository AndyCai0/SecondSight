import { runFunction } from '../_shared/runtime.ts'

export const handler = (request: Request) => runFunction('risk-event', request)

export default { fetch: handler }
