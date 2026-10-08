import Cocoa
import Testing
@testable import macshot

/// Stamps are rendered from emoji into images that get baked into a capture.
@MainActor
final class StampEmojiTests {

    @Test func testEveryCategoryHasANameAndContent() {
        #expect(!StampEmojis.categories.isEmpty)
        for (name, emoji) in StampEmojis.categories {
            #expect(!name.isEmpty, "a category tab with no name")
            #expect(!emoji.isEmpty, "category \(name) has no emoji")
        }
    }

    @Test func testNoEmojiIsListedTwiceInTheSameCategory() {
        for (name, emoji) in StampEmojis.categories {
            #expect(Set(emoji).count == emoji.count, "category \(name) repeats an emoji")
        }
    }

    @Test func testTheCommonListIsAvailableInTheCategories() {
        let all = Set(StampEmojis.categories.flatMap { $0.1 })
        for emoji in StampEmojis.common {
            #expect(all.contains(emoji), "\(emoji) is offered as a default but isn't in any category")
        }
    }

    @Test func testRenderingProducesAVisibleImage() throws {
        let image = StampEmojis.renderEmoji("🎉", size: 64)
        #expect(image.size == NSSize(width: 64, height: 64))

        let bitmap = try #require(ImageProbe.bitmap(from: image))
        var opaquePixels = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                opaquePixels += 1
            }
        }
        #expect(opaquePixels > 10, "the stamp rendered blank")
    }

    @Test func testEveryOfferedEmojiRenders() {
        // A stamp that renders blank would paste an invisible annotation.
        for (category, emoji) in StampEmojis.categories {
            for character in emoji {
                let image = StampEmojis.renderEmoji(character, size: 24)
                #expect(image.size.width > 0, "\(character) in \(category) rendered no image")
            }
        }
    }

    @Test func testOddInputDoesNotCrashTheRenderer() {
        for text in ["", " ", "not an emoji", "👨‍👩‍👧‍👦", "🇯🇵"] {
            _ = StampEmojis.renderEmoji(text, size: 32)
        }
    }

    @Test func testSizeIsRespected() {
        for size in [8, 32, 256] as [CGFloat] {
            #expect(StampEmojis.renderEmoji("⭐️", size: size).size == NSSize(width: size, height: size))
        }
    }
}
