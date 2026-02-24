/**
 * Entity Resolver — Maps OpenClaw channel context to Composio entity IDs.
 *
 * Each Composio entity is an isolated credential vault. This module resolves
 * the correct entity_id from the channel + peer identity of the current
 * conversation, enabling multi-tenant operation.
 *
 * Resolution order:
 *   1. Explicit mapping in entity-map.json (channel:peer -> entityId)
 *   2. Default entity ID from config
 */

import { readFileSync, existsSync } from "node:fs";

export interface EntityMapping {
  /** Composio entity ID for this identity */
  composioEntityId: string;
  /** Human-readable label */
  label?: string;
}

export interface EntityMap {
  /** Map from canonical user ID -> entity mapping */
  entities: Record<string, EntityMapping>;
  /** Map from channel alias -> canonical user ID */
  aliases: Record<string, string>;
}

/**
 * Load entity map from JSON file.
 */
export function loadEntityMap(path?: string): EntityMap | null {
  if (!path || !existsSync(path)) return null;

  try {
    const raw = JSON.parse(readFileSync(path, "utf-8"));
    return {
      entities: raw.entities || {},
      aliases: raw.aliases || {},
    };
  } catch {
    return null;
  }
}

/**
 * Resolve a Composio entity ID from conversation context.
 *
 * @param entityMap - Loaded entity map
 * @param channelKey - Channel identifier (e.g. "telegram:dm:andrew")
 * @param defaultEntityId - Fallback entity ID
 * @returns The resolved Composio entity ID
 */
export function resolveEntityId(
  entityMap: EntityMap | null,
  channelKey: string,
  defaultEntityId: string,
): string {
  if (!entityMap) return defaultEntityId;

  // Try direct alias match first
  const canonicalId = entityMap.aliases[channelKey];
  if (canonicalId && entityMap.entities[canonicalId]) {
    return entityMap.entities[canonicalId].composioEntityId;
  }

  // Try prefix matching (e.g. "telegram:dm:" matches "telegram:dm:andrew")
  for (const [alias, canonical] of Object.entries(entityMap.aliases)) {
    if (channelKey.startsWith(alias) || alias.startsWith(channelKey)) {
      const entity = entityMap.entities[canonical];
      if (entity) return entity.composioEntityId;
    }
  }

  return defaultEntityId;
}
