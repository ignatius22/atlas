/**
 * Atlas Disaster Recovery & Backup Management API Service
 */

export interface SystemSummary {
    timestamp: string
    host: string
    os: string
    disk: {
        total_gb: number
        used_gb: number
        free_gb: number
        percent: number
    }
    containers: Array<{
        name: string
        id_short: string
        status: string
        health: string
        started: string
    }>
    security: {
        private_keys_on_vps: number
        zero_knowledge_intact: boolean
        recipient_configured: boolean
        recipient_masked: string
    }
    offsite: {
        provider: string
        bucket: string
        configured: boolean
    }
    scheduler: {
        type: string
        active: boolean
        rpo: string
    }
}

export interface BackupItem {
    app: string
    filename: string
    size_bytes: number
    size_human: string
    modified: string
    sha256: string
    sha256_short: string
    has_age: boolean
    age_size_bytes: number
    metadata: Record<string, any>
}

export interface RemoteObjectsResponse {
    configured: boolean
    bucket: string
    total_objects: number
    objects: string[]
    error?: string
}

export interface ActionResult {
    action: string
    exit_code: number
    output: string
    app?: string
    error?: string
}

export const getAuthToken = (): string => {
    return sessionStorage.getItem('atlas_token') || ''
}

export const setAuthToken = (token: string) => {
    sessionStorage.setItem('atlas_token', token)
}

export const clearAuthToken = () => {
    sessionStorage.removeItem('atlas_token')
}

export const fetchStatus = async (): Promise<SystemSummary> => {
    const res = await fetch('/api/status', {
        headers: { 'X-Atlas-Token': getAuthToken() },
    })
    if (!res.ok) {
        throw new Error(`Failed to fetch system status (${res.status})`)
    }
    return res.json()
}

export const fetchBackups = async (): Promise<Record<string, BackupItem[]>> => {
    const res = await fetch('/api/backups', {
        headers: { 'X-Atlas-Token': getAuthToken() },
    })
    if (!res.ok) {
        throw new Error(`Failed to fetch backups (${res.status})`)
    }
    return res.json()
}

export const fetchOffsite = async (): Promise<RemoteObjectsResponse> => {
    const res = await fetch('/api/offsite', {
        headers: { 'X-Atlas-Token': getAuthToken() },
    })
    if (!res.ok) {
        throw new Error(`Failed to fetch offsite storage (${res.status})`)
    }
    return res.json()
}

export const triggerBackup = async (app: string = '--all'): Promise<ActionResult> => {
    const res = await fetch('/api/actions/backup', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'X-Atlas-Token': getAuthToken(),
        },
        body: JSON.stringify({ app }),
    })
    return res.json()
}

export const triggerSync = async (app: string = '--all'): Promise<ActionResult> => {
    const res = await fetch('/api/actions/sync', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'X-Atlas-Token': getAuthToken(),
        },
        body: JSON.stringify({ app }),
    })
    return res.json()
}

export const triggerRestoreTest = async (app: string): Promise<ActionResult> => {
    const res = await fetch('/api/actions/restore-test', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'X-Atlas-Token': getAuthToken(),
        },
        body: JSON.stringify({ app }),
    })
    return res.json()
}

export const fetchDoctor = async (): Promise<ActionResult> => {
    const res = await fetch('/api/doctor', {
        headers: { 'X-Atlas-Token': getAuthToken() },
    })
    return res.json()
}

export const fetchHealth = async (): Promise<{ status: string; service: string }> => {
    const res = await fetch('/api/health')
    return res.json()
}
