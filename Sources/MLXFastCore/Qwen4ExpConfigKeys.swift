import Foundation

/// The Qwen 3.8 125B A6B target's transformed runtime `config.json` key-set
/// contract, shared between `Qwen4ExpEngineConfig`
/// (`Sources/MLXFastModel/Qwen4ExpEngineConfig.swift`, the participant
/// worker's config loader) and the trusted runtime-worker pinned-configuration
/// gate (`validateRuntimeWorkerPinnedConfigurationData` in both
/// `Sources/MLXFastHarness/Gemma4RuntimeWorker.swift` and its
/// `Sources/MLXFastTrustedHarness` twin).
///
/// This lives in `MLXFastCore` -- which carries no MLX or model dependency and
/// is linked by every target in this package, including the trusted
/// `mlxfast-swift` binary, which deliberately does NOT depend on
/// `MLXFastModel` -- specifically so the participant-side loader and the
/// trusted-side gate cannot silently diverge on WHICH keys this target's
/// config carries.
///
/// The frozen SCALAR invariants (`vocab_size`, `hidden_size`,
/// `num_hidden_layers`, ...) do not need a similar home: they already live on
/// `MLXFastConstants` in this same module, and both the loader and the trusted
/// gate read them from there.
public enum Qwen4ExpConfigKeys {
    /// Every key the transformed config must carry, non-null.
    ///
    /// READ OFF the pinned revision's own `text_config`, which carries exactly
    /// these 53 non-null keys plus one null (`pad_token_id`, see `nullable`).
    /// The transform flattens `text_config` to the top level and adds the
    /// checkpoint-wide `quantization` block beside it.
    public static let required: Set<String> = [
        "attention_bias", "attention_dropout", "bos_token_id", "dtype",
        "eos_token_id", "full_attention_interval", "hc_count", "hc_lowrank",
        "head_dim", "heads_per_ngram", "hidden_act", "hidden_size",
        "indexer_budget", "indexer_compress_ratio", "indexer_head_dim",
        "indexer_kv_heads", "indexer_n_heads", "initializer_range",
        "layer_types", "linear_conv_kernel_dim", "linear_key_head_dim",
        "linear_num_key_heads", "linear_num_value_heads",
        "linear_value_head_dim", "make_ngram_vocab_size_divisible_by",
        "mamba_ssm_dtype", "max_position_embeddings", "model_type",
        "moe_intermediate_size", "mtp", "mtp_num_hidden_layers",
        "mtp_use_dedicated_embeddings", "ngram_size", "ngram_vocab_size_base",
        "num_attention_heads", "num_experts", "num_experts_per_tok",
        "num_hidden_layers", "num_key_value_heads", "output_gate_type",
        "output_router_logits", "partial_rotary_factor",
        "ple_conv_kernel_size", "ple_embed_dim", "ple_layer_ids",
        "rms_norm_eps", "rope_parameters", "router_aux_loss_coef",
        "shared_expert_intermediate_size", "split_ngram_parts",
        "tie_word_embeddings", "use_cache", "vocab_size",
    ]

    /// Keys the config carries with a NULL value. They must be PRESENT and
    /// NULL: a null that turns into a number is a change of contract, and so
    /// is a key that disappears.
    public static let nullable: Set<String> = ["pad_token_id"]

    /// Keys that must be ABSENT or null.
    ///
    /// `sliding_window` and `final_logit_softcapping` are the Gemma-family
    /// knobs this tree was seeded with: this target has neither, and a config
    /// that carried one would mean the worker was handed the wrong checkpoint.
    /// `qkv_bias` and `query_pre_attn_scalar` change attention. A key that
    /// silently appears is exactly as dangerous as one that disappears.
    public static let forbidden: [String] = [
        "final_logit_softcapping", "moe_router_logit_softcapping", "qkv_bias",
        "query_pre_attn_scalar", "sliding_window",
    ]

    /// The extra key the runtime `config.json` carries beyond `required`: the
    /// checkpoint-wide quantization block. Its own shape is validated
    /// separately, not by exact key-set equality, so it is not part of
    /// `required`.
    public static let quantizationKey = "quantization"

    /// Keys of the nested `mtp` block, which describes the head EMBEDDED in
    /// this checkpoint. `mtp_use_hidden_state_from_layer` is null here.
    public static let mtpRequired: Set<String> = [
        "hybrid", "layer_types", "mtp_use_hidden_state_from_layer",
        "num_hidden_layers", "rope_theta",
    ]

    /// Keys of the nested `rope_parameters` block.
    public static let ropeRequired: Set<String> = [
        "mrope_interleaved", "mrope_section", "partial_rotary_factor",
        "rope_theta", "type",
    ]
}
