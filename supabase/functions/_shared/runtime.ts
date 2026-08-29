import { createProductionDependencies } from './dependencies.ts'
import {
  AIUnavailableError,
  type EdgeDependencies,
  type EdgeFunctionName,
  handleEdgeRequest,
  jsonResponse,
  preflightResponse,
  ServerOperationError,
} from './handler.ts'

type DependenciesFactory = () => EdgeDependencies
type ErrorReporter = (error: unknown) => void

export async function runFunction(
  functionName: EdgeFunctionName,
  request: Request,
  createDependencies: DependenciesFactory = createProductionDependencies,
  reportError: ErrorReporter = console.error,
): Promise<Response> {
  if (request.method === 'OPTIONS') return preflightResponse()
  try {
    return await handleEdgeRequest(functionName, request, createDependencies())
  } catch (error) {
    if (error instanceof AIUnavailableError) {
      return jsonResponse({ error: error.message }, 503)
    }
    if (error instanceof ServerOperationError) {
      reportError(error)
      return jsonResponse({
        error: 'Internal server error',
        code: error.code,
        provider_code: error.providerCode,
      }, 500)
    }
    reportError(error)
    return jsonResponse({ error: 'Internal server error' }, 500)
  }
}
