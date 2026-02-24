/**
 * OpenClaw Composio Plugin — Native integration layer for 1000+ services.
 *
 * Instead of managing 20+ API keys per client, Composio handles all OAuth
 * tokens centrally. Each client gets an isolated "entity" (credential vault),
 * and the bot calls Composio to execute actions on behalf of that entity.
 *
 * Architecture:
 *   1. Plugin initializes Composio client with API key
 *   2. Entity resolver maps channel context -> Composio entity_id
 *   3. For each configured toolkit, available actions are registered as tools
 *   4. Tool execution passes the resolved entity_id to Composio
 *   5. Connect/status tools enable onboarding via OAuth Connect Links
 */

import { Composio } from "@composio/core";
import {
  loadEntityMap,
  resolveEntityId,
  type EntityMap,
} from "./entity-resolver.js";
import {
  generateConnectLink,
  getConnectionStatus,
} from "./connect-links.js";

// ============================================================================
// Config types
// ============================================================================

interface ComposioPluginConfig {
  apiKey: string;
  defaultEntityId: string;
  entityMapPath?: string;
  toolkits: string[];
  toolPrefix: string;
  connectLinkRedirect?: string;
}

// ============================================================================
// Config validation
// ============================================================================

const ALLOWED_CONFIG_KEYS = [
  "apiKey",
  "defaultEntityId",
  "entityMapPath",
  "toolkits",
  "toolPrefix",
  "connectLinkRedirect",
];

function parseConfig(raw: unknown): ComposioPluginConfig {
  const obj = (raw || {}) as Record<string, unknown>;

  const apiKey =
    typeof obj.apiKey === "string"
      ? obj.apiKey
      : process.env.COMPOSIO_API_KEY || "";

  if (!apiKey) {
    throw new Error(
      "openclaw-composio: API key required. Set COMPOSIO_API_KEY env var or config.apiKey",
    );
  }

  return {
    apiKey,
    defaultEntityId:
      typeof obj.defaultEntityId === "string" ? obj.defaultEntityId : "default",
    entityMapPath:
      typeof obj.entityMapPath === "string" ? obj.entityMapPath : undefined,
    toolkits: Array.isArray(obj.toolkits)
      ? (obj.toolkits as string[])
      : ["gmail", "googlecalendar"],
    toolPrefix:
      typeof obj.toolPrefix === "string" ? obj.toolPrefix : "composio",
    connectLinkRedirect:
      typeof obj.connectLinkRedirect === "string"
        ? obj.connectLinkRedirect
        : undefined,
  };
}

// ============================================================================
// Plugin entry point
// ============================================================================

export default {
  id: "openclaw-composio",

  register(api: any, rawConfig: unknown) {
    const cfg = parseConfig(rawConfig);

    api.logger.info(
      `openclaw-composio: initializing with ${cfg.toolkits.length} toolkits, prefix="${cfg.toolPrefix}"`,
    );

    // Initialize Composio client
    let composio: Composio;
    try {
      composio = new Composio({ apiKey: cfg.apiKey });
    } catch (err) {
      api.logger.error(
        `openclaw-composio: failed to initialize Composio client: ${err}`,
      );
      return;
    }

    // Load entity map for multi-tenant resolution
    const entityMapPath = cfg.entityMapPath
      ? api.resolvePath(cfg.entityMapPath)
      : undefined;
    const entityMap: EntityMap | null = loadEntityMap(entityMapPath);

    if (entityMap) {
      const entityCount = Object.keys(entityMap.entities).length;
      api.logger.info(
        `openclaw-composio: loaded entity map with ${entityCount} entities`,
      );
    }

    // Helper to resolve entity ID from session context
    function getEntityId(ctx: any): string {
      // Try to get channel + peer from session context
      const channel = ctx?.channel || "";
      const peer = ctx?.peer || "";
      const channelKey = peer ? `${channel}:${peer}` : channel;

      return resolveEntityId(entityMap, channelKey, cfg.defaultEntityId);
    }

    // ---- Register composio_connect tool ----
    api.registerTool({
      name: `${cfg.toolPrefix}_connect`,
      label: "Connect Service (OAuth)",
      description:
        "Generate an OAuth Connect Link for a service. The user clicks the link to authorize access. " +
        "Use this during onboarding to connect Gmail, Calendar, Slack, etc.",
      parameters: {
        type: "object",
        properties: {
          toolkit: {
            type: "string",
            description:
              "Service to connect (e.g. gmail, googlecalendar, slack, notion, github, twitter)",
          },
          entity_id: {
            type: "string",
            description:
              "Optional: specific Composio entity ID. If omitted, auto-resolved from channel context.",
          },
        },
        required: ["toolkit"],
      },
      execute: async (args: any, ctx: any) => {
        const entityId = args.entity_id || getEntityId(ctx);
        const toolkit = args.toolkit;

        try {
          const link = await generateConnectLink(
            composio,
            entityId,
            toolkit,
            cfg.connectLinkRedirect,
          );

          return {
            content: [
              {
                type: "text",
                text: `Connect Link for ${toolkit}:\n\n${link.redirectUrl}\n\nConnection ID: ${link.connectionId}\nEntity: ${entityId}\n\nSend this link to the user so they can authorize access.`,
              },
            ],
          };
        } catch (err) {
          return {
            content: [
              {
                type: "text",
                text: `Failed to generate Connect Link for ${toolkit}: ${err}`,
              },
            ],
            isError: true,
          };
        }
      },
    });

    // ---- Register composio_connections_status tool ----
    api.registerTool({
      name: `${cfg.toolPrefix}_connections_status`,
      label: "Check Connected Services",
      description:
        "Check which services are connected for the current user/entity. " +
        "Returns a list of configured toolkits and their connection status.",
      parameters: {
        type: "object",
        properties: {
          entity_id: {
            type: "string",
            description:
              "Optional: specific Composio entity ID. If omitted, auto-resolved from channel context.",
          },
        },
      },
      execute: async (args: any, ctx: any) => {
        const entityId = args.entity_id || getEntityId(ctx);

        try {
          const status = await getConnectionStatus(
            composio,
            entityId,
            cfg.toolkits,
          );

          const lines = Object.entries(status).map(
            ([toolkit, connected]) =>
              `${connected ? "✓" : "✗"} ${toolkit}: ${connected ? "connected" : "not connected"}`,
          );

          return {
            content: [
              {
                type: "text",
                text: `Connection status for entity "${entityId}":\n\n${lines.join("\n")}`,
              },
            ],
          };
        } catch (err) {
          return {
            content: [
              {
                type: "text",
                text: `Failed to check connection status: ${err}`,
              },
            ],
            isError: true,
          };
        }
      },
    });

    // ---- Register composio_execute tool (generic action executor) ----
    api.registerTool({
      name: `${cfg.toolPrefix}_execute`,
      label: "Execute Composio Action",
      description:
        "Execute any Composio action by slug. Use composio_list_actions to discover available actions first. " +
        "Pass the action slug and its required arguments.",
      parameters: {
        type: "object",
        properties: {
          action: {
            type: "string",
            description:
              'The Composio action slug to execute (e.g. "GMAIL_SEND_EMAIL", "GOOGLECALENDAR_CREATE_EVENT")',
          },
          arguments: {
            type: "object",
            description: "Arguments for the action (varies by action)",
            additionalProperties: true,
          },
          entity_id: {
            type: "string",
            description:
              "Optional: specific Composio entity ID. If omitted, auto-resolved from channel context.",
          },
        },
        required: ["action"],
      },
      execute: async (args: any, ctx: any) => {
        const entityId = args.entity_id || getEntityId(ctx);

        try {
          const result = await composio.tools.execute(args.action, {
            userId: entityId,
            arguments: args.arguments || {},
          });

          return {
            content: [
              {
                type: "text",
                text:
                  typeof result === "string"
                    ? result
                    : JSON.stringify(result, null, 2),
              },
            ],
          };
        } catch (err) {
          return {
            content: [
              {
                type: "text",
                text: `Failed to execute ${args.action}: ${err}`,
              },
            ],
            isError: true,
          };
        }
      },
    });

    // ---- Register composio_list_actions tool ----
    api.registerTool({
      name: `${cfg.toolPrefix}_list_actions`,
      label: "List Available Composio Actions",
      description:
        "List available actions for a toolkit or search for actions. " +
        "Returns action slugs that can be used with composio_execute.",
      parameters: {
        type: "object",
        properties: {
          toolkit: {
            type: "string",
            description:
              "Toolkit name to list actions for (e.g. gmail, slack, github)",
          },
          search: {
            type: "string",
            description:
              "Search query to find actions (e.g. 'send email', 'create event')",
          },
          entity_id: {
            type: "string",
            description:
              "Optional: specific Composio entity ID. If omitted, auto-resolved from channel context.",
          },
        },
      },
      execute: async (args: any, ctx: any) => {
        const entityId = args.entity_id || getEntityId(ctx);

        try {
          const opts: any = { limit: 20 };
          if (args.toolkit) {
            opts.toolkits = [args.toolkit.toUpperCase()];
          }
          if (args.search) {
            opts.search = args.search;
          }

          const tools = await composio.tools.get(entityId, opts);

          if (!tools || tools.length === 0) {
            return {
              content: [
                {
                  type: "text",
                  text: args.toolkit
                    ? `No actions found for toolkit "${args.toolkit}". It may not be connected yet — use ${cfg.toolPrefix}_connect to set it up.`
                    : "No actions found matching your search.",
                },
              ],
            };
          }

          const actionList = tools
            .map((t: any) => {
              const name = t.function?.name || t.name || "unknown";
              const desc =
                t.function?.description || t.description || "No description";
              return `- ${name}: ${desc.slice(0, 100)}`;
            })
            .join("\n");

          return {
            content: [
              {
                type: "text",
                text: `Available actions (${tools.length} found):\n\n${actionList}`,
              },
            ],
          };
        } catch (err) {
          return {
            content: [
              {
                type: "text",
                text: `Failed to list actions: ${err}`,
              },
            ],
            isError: true,
          };
        }
      },
    });

    api.logger.info(
      `openclaw-composio: registered 4 tools (${cfg.toolPrefix}_connect, ${cfg.toolPrefix}_connections_status, ${cfg.toolPrefix}_execute, ${cfg.toolPrefix}_list_actions)`,
    );
  },
};
