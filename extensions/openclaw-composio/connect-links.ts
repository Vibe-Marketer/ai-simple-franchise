/**
 * Connect Links — Generate OAuth authorization URLs for client onboarding.
 *
 * During BOOTSTRAP.md conversations, the agent sends Connect Links to the user.
 * The user clicks, authorizes in their browser, and Composio stores the OAuth
 * tokens forever (with auto-refresh).
 */

import { Composio } from "@composio/core";

/**
 * Generate an OAuth Connect Link for a specific toolkit.
 *
 * @param composio - Initialized Composio client
 * @param entityId - The Composio entity ID to connect for
 * @param toolkit - Toolkit name (e.g. "gmail", "googlecalendar", "slack")
 * @param redirectUrl - Where to redirect after OAuth completes
 * @returns Object with redirectUrl and connectionId
 */
export async function generateConnectLink(
  composio: Composio,
  entityId: string,
  toolkit: string,
  redirectUrl?: string,
): Promise<{ redirectUrl: string; connectionId: string }> {
  const connRequest = await composio.connectedAccounts.initiate(
    entityId,
    toolkit.toUpperCase(),
  );

  return {
    redirectUrl: connRequest.redirectUrl,
    connectionId: connRequest.id,
  };
}

/**
 * Check the connection status for an entity's toolkit.
 *
 * @param composio - Initialized Composio client
 * @param entityId - The Composio entity ID
 * @param toolkit - Toolkit name to check
 * @returns Whether the toolkit is connected
 */
export async function isToolkitConnected(
  composio: Composio,
  entityId: string,
  toolkit: string,
): Promise<boolean> {
  try {
    const tools = await composio.tools.get(entityId, {
      toolkits: [toolkit.toUpperCase()],
      limit: 1,
    });
    return tools.length > 0;
  } catch {
    return false;
  }
}

/**
 * Get all connected toolkits for an entity.
 *
 * @param composio - Initialized Composio client
 * @param entityId - The Composio entity ID
 * @param toolkits - List of toolkit names to check
 * @returns Map of toolkit name -> connected status
 */
export async function getConnectionStatus(
  composio: Composio,
  entityId: string,
  toolkits: string[],
): Promise<Record<string, boolean>> {
  const status: Record<string, boolean> = {};

  for (const toolkit of toolkits) {
    status[toolkit] = await isToolkitConnected(composio, entityId, toolkit);
  }

  return status;
}
