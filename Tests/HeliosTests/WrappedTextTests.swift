import XCTest
@testable import Helios

final class WrappedTextTests: XCTestCase {
    // A command claude wrapped in a 74-column pane: two mid-word breaks, then one at a space.
    let wrapped = """
    python -m analysis.sweep models/geo_torus_t300_k6_d*_l4_h4_b4096_st30000
      _grpo_G32_q1_ri-0.1_efficiency_mask_untied models/geo_torus_t300_k6_d64_
      l4_h4_b4096_st10000_grpo_G32_q1_ri-0.1_efficiency_mask_untied --x
      d_model --name width_30k && open models/sweep_width_30k.html
    """
    let original = "python -m analysis.sweep models/geo_torus_t300_k6_d*_l4_h4_b4096_st30000_grpo_G32_q1_ri-0.1_efficiency_mask_untied models/geo_torus_t300_k6_d64_l4_h4_b4096_st10000_grpo_G32_q1_ri-0.1_efficiency_mask_untied --x d_model --name width_30k && open models/sweep_width_30k.html"

    func testUnwrapsClaudeWrappedCommand() {
        XCTAssertEqual(WrappedText.unwrap(wrapped, firstColumn: 2, cols: 74), original)
    }

    func testSelectionIncludingIndent() {
        XCTAssertEqual(WrappedText.unwrap("  " + wrapped, firstColumn: 0, cols: 74), original)
    }

    // A short word that ends exactly at (or one before) the pane edge was moved, not split:
    // joining without a space produced `--reward efficiency--mask_neighbors` and failed jobs.
    func testWordEndingAtEdgeKeepsSpace() {
        let first = "python train.py --reward efficiency"
        let text = first + "\n  --mask_neighbors --seed 1"
        let expected = "python train.py --reward efficiency --mask_neighbors --seed 1"
        XCTAssertEqual(WrappedText.unwrap(text, firstColumn: 2, cols: 2 + first.count), expected)
        XCTAssertEqual(WrappedText.unwrap(text, firstColumn: 2, cols: 3 + first.count), expected)
    }

    func testKeepsRealLineBreaks() {
        XCTAssertNil(WrappedText.unwrap("ls\ncd foo\ngit status", firstColumn: 0, cols: 74))
        XCTAssertNil(WrappedText.unwrap("def f():\n  return 1\n  pass", firstColumn: 0, cols: 74))
        XCTAssertNil(WrappedText.unwrap("echo hi", firstColumn: 0, cols: 74))
    }
}
