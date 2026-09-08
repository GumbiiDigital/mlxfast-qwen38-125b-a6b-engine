import CryptoKit
import Foundation
import MLXFastCore
@testable import MLXFastTransform

/// The identity of the checkpoint `fixtures/qwen3_8_125b_a6b_config.json` was
/// captured from.
///
/// RETAINED, NOT CURRENT. The track moved to Qwen 3.8 125B A6B, and
/// `MLXFastConstants.referenceModelRepository` / `_Revision` now name that
/// target. This fixture and these two constants keep naming the Gemma 4 26B
/// A4B checkpoint because the GEMMA MODEL CODE they validate is still what
/// the transform validates. They move when
/// that code moves, the same way the retained Qwen 3.6 fixtures record a
/// superseded backbone on purpose. The CURRENT target's fixtures live in
/// `Qwen38A6BTrackFixtureSupport.swift`
/// (`docs/qwen38-125b-a6b-port-notes.md`).
let qwen4ExpRepository = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
let qwen4ExpRevision = "0e3cbab38ce568cf6e23543010d08d03b731910c"

/// SHA256 of the checkpoint's own `config.json` bytes exactly as published at
/// the pinned revision (fetched 2026-08-23 from
/// `https://huggingface.co/mlx-community/gemma-4-26B-A4B-it-qat-4bit/raw/0e3cbab38ce568cf6e23543010d08d03b731910c/config.json`,
/// revision confirmed via the HF API to resolve to this exact commit, not a
/// branch alias) -- NOT of the normalized `fixtures/qwen3_8_125b_a6b_config.json`
/// re-render checked into this repository, which differs only in whitespace
/// and key order (`JSONSerialization`-equivalent re-encoding: 2-space indent,
/// keys sorted, trailing newline -- reproduced with
/// `json.dumps(d, indent=2, sort_keys=True) + "\n"`, verified byte-identical
/// to this repository's existing `fixtures/qwen3_6_27b_config.json` round trip
/// before being applied here).
///
/// THIS IS A LAPTOP-SIDE PUBLIC FETCH, NOT A BOX-VERIFIED ARTIFACT. It proves
/// the fixture matches what the pinned HF revision publishes today; it does
/// NOT prove it matches the byte the ranked box's transform actually reads
/// (docs/qwen38-125b-a6b-port-notes.md still calls that box-only). Do not
/// promote this digest to a manifest pin without a box-side re-verification.
let qwen4ExpConfigSHA256 =
    "1457a22a7f404c57f861e9024ca8c7e8abd6fad8e614af55c45a10de059452bb"

// Tests/MLXFastTests/Model/<this file> -> repository root is four levels up.
private let qwen4ExpArtifactRepositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let qwen4ExpConfigFixtureURL = qwen4ExpArtifactRepositoryRoot
    .appendingPathComponent("fixtures/qwen3_8_125b_a6b_config.json")

func qwen4ExpConfigData() throws -> Data {
    try Data(contentsOf: qwen4ExpConfigFixtureURL)
}

func qwen4ExpConfigObject() throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(
        with: qwen4ExpConfigData()
    ) as? [String: Any] else {
        throw MLXFastError.invalidInput("Qwen 3.8 125B A6B config fixture must be a JSON object")
    }
    return object
}
