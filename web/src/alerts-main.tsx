import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import './AlertsPage.css'
import AlertsPage from './AlertsPage'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <AlertsPage />
  </StrictMode>,
)
