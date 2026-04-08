import type { Plugin } from "@opencode-ai/plugin";

// From <https://github.com/remorses/kimaki/commit/620cb703c3da3d3a7b8b7e58ab9a3c2b94f4b631>:
export const AnthropicAuthPromptPlugin: Plugin = async ({
  project,
  client,
  $,
  directory,
  worktree,
}) => {
  return {
    "experimental.chat.system.transform": async (input, output) => {
      if (input.model.providerID !== "anthropic") return;
      const opencodePromptPart = output.system.findIndex((x) =>
        x?.includes("https://github.com/anomalyco/opencode"),
      );
      // Remove the OpenCode system prompt part if present
      if (opencodePromptPart !== -1) {
        output.system.splice(opencodePromptPart, 1);
      }
    },
  };
};
