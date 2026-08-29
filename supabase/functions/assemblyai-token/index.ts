import { runFunction } from '../_shared/runtime.ts'

export const handler = (request: Request) => runFunction('assemblyai-token', request)

export default { fetch: handler }
