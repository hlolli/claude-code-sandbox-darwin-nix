import type { Plugin } from "@opencode-ai/plugin";

// Based on <https://github.com/remorses/kimaki/commit/620cb703c3da3d3a7b8b7e58ab9a3c2b94f4b631>:

const OPENCODE_PROMPT_MARKER = "https://github.com/anomalyco/opencode";
const PRESERVED_TAIL_MARKERS = [
  // "\nYou are powered by the model named ",
  // "\nHere is some useful information about the environment ",
  // "\nSkills provide specialized instructions and workflows for specific tasks.",
  "\nInstructions from: ", // keep the preamble.md
  "\nInstructions from command: ", // keep the OPENCODE_EXTRA_INSTRUCTIONS_COMMAND output
];

function stripOpenCodeSystemPrompt(systemPrompt: string) {
  if (!systemPrompt.includes(OPENCODE_PROMPT_MARKER)) return systemPrompt;

  const tailIndex = PRESERVED_TAIL_MARKERS.reduce<number>(
    (bestIndex, marker) => {
      const index = systemPrompt.indexOf(marker);
      if (index === -1) return bestIndex;
      if (bestIndex === -1 || index < bestIndex) return index;
      return bestIndex;
    },
    -1,
  );

  if (tailIndex === -1) return "";
  return systemPrompt.slice(tailIndex + 1);
}

export const AnthropicAuthPromptPlugin: Plugin = async () => {
  return {
    "experimental.chat.system.transform": async (input, output) => {
      if (input.model.providerID !== "anthropic") return;
      const nextSystem = output.system
        .map(stripOpenCodeSystemPrompt)
        .filter((systemPrompt) => systemPrompt.length > 0);

      output.system.splice(0, output.system.length, ...nextSystem);
    },
  };
};
