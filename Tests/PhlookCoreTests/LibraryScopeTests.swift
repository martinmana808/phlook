import Testing
import Foundation
@testable import PhlookCore

struct LibraryScopeTests {
    func mkItem(path: String, fileType: String, hidden: Bool = false,
                kindFlags: Int = 0, dateTaken: Date? = nil) -> MediaItem {
        MediaItem(path: path, hash: "h", dateTaken: dateTaken, fileType: fileType,
                  width: nil, height: nil, lastScanned: Date(), hidden: hidden, kindFlags: kindFlags)
    }

    // MARK: - Hidden exclusion / inversion

    @Test func allExcludesHidden() {
        let visible = mkItem(path: "/a.jpg", fileType: "image")
        let hidden = mkItem(path: "/b.jpg", fileType: "image", hidden: true)
        #expect(LibraryScope.all.matches(visible, livePairs: .empty))
        #expect(!LibraryScope.all.matches(hidden, livePairs: .empty))
    }

    @Test func everyNonHiddenScopeExcludesHiddenItems() {
        let hiddenPhoto = mkItem(path: "/p.jpg", fileType: "image", hidden: true, kindFlags: 3)
        let hiddenVideo = mkItem(path: "/v.mov", fileType: "video", hidden: true)
        let livePairs = LivePairs.compute(items: [
            mkItem(path: "/live.jpg", fileType: "image", hidden: true),
        ])
        for scope in LibraryScope.allCases where scope != .hidden {
            #expect(!scope.matches(hiddenPhoto, livePairs: livePairs))
            #expect(!scope.matches(hiddenVideo, livePairs: livePairs))
        }
    }

    @Test func hiddenScopeShowsOnlyHiddenItems() {
        let visible = mkItem(path: "/a.jpg", fileType: "image")
        let hidden = mkItem(path: "/b.jpg", fileType: "image", hidden: true)
        #expect(!LibraryScope.hidden.matches(visible, livePairs: .empty))
        #expect(LibraryScope.hidden.matches(hidden, livePairs: .empty))
    }

    // MARK: - Photos / Videos

    @Test func photosMatchesImagesOnly() {
        let image = mkItem(path: "/a.jpg", fileType: "image")
        let video = mkItem(path: "/a.mov", fileType: "video")
        #expect(LibraryScope.photos.matches(image, livePairs: .empty))
        #expect(!LibraryScope.photos.matches(video, livePairs: .empty))
    }

    @Test func videosMatchesVideosOnly() {
        let image = mkItem(path: "/a.jpg", fileType: "image")
        let video = mkItem(path: "/a.mov", fileType: "video")
        #expect(!LibraryScope.videos.matches(image, livePairs: .empty))
        #expect(LibraryScope.videos.matches(video, livePairs: .empty))
    }

    // MARK: - Live

    @Test func liveStillCountsAsPhotoAndLive() {
        let still = mkItem(path: "/dir/IMG_0001.jpg", fileType: "image")
        let motion = mkItem(path: "/dir/IMG_0001.mov", fileType: "video", dateTaken: nil)
        var motionWithDuration = motion
        motionWithDuration.duration = 2.0
        let livePairs = LivePairs.compute(items: [still, motionWithDuration])
        #expect(LibraryScope.live.matches(still, livePairs: livePairs))
        #expect(LibraryScope.photos.matches(still, livePairs: livePairs))
    }

    @Test func nonLiveImageDoesNotMatchLive() {
        let solo = mkItem(path: "/solo.jpg", fileType: "image")
        #expect(!LibraryScope.live.matches(solo, livePairs: .empty))
    }

    @Test func liveNeverMatchesVideos() {
        let video = mkItem(path: "/a.mov", fileType: "video")
        #expect(!LibraryScope.live.matches(video, livePairs: .empty))
    }

    // MARK: - Kind flags

    @Test func screenshotsMatchesScreenshotFlagOnly() {
        let screenshot = mkItem(path: "/s.png", fileType: "image", kindFlags: KindFlags.screenshot.rawValue)
        let selfie = mkItem(path: "/f.jpg", fileType: "image", kindFlags: KindFlags.selfie.rawValue)
        let plain = mkItem(path: "/p.jpg", fileType: "image")
        #expect(LibraryScope.screenshots.matches(screenshot, livePairs: .empty))
        #expect(!LibraryScope.screenshots.matches(selfie, livePairs: .empty))
        #expect(!LibraryScope.screenshots.matches(plain, livePairs: .empty))
    }

    @Test func selfiesMatchesSelfieFlagOnly() {
        let selfie = mkItem(path: "/f.jpg", fileType: "image", kindFlags: KindFlags.selfie.rawValue)
        let screenshot = mkItem(path: "/s.png", fileType: "image", kindFlags: KindFlags.screenshot.rawValue)
        #expect(LibraryScope.selfies.matches(selfie, livePairs: .empty))
        #expect(!LibraryScope.selfies.matches(screenshot, livePairs: .empty))
    }

    @Test func combinedFlagsMatchBothScopes() {
        let both = mkItem(path: "/b.jpg", fileType: "image",
                           kindFlags: KindFlags.screenshot.rawValue | KindFlags.selfie.rawValue)
        #expect(LibraryScope.screenshots.matches(both, livePairs: .empty))
        #expect(LibraryScope.selfies.matches(both, livePairs: .empty))
    }

    @Test func flagScopesNeverMatchVideos() {
        let video = mkItem(path: "/a.mov", fileType: "video",
                            kindFlags: KindFlags.screenshot.rawValue | KindFlags.selfie.rawValue)
        #expect(!LibraryScope.screenshots.matches(video, livePairs: .empty))
        #expect(!LibraryScope.selfies.matches(video, livePairs: .empty))
    }
}

struct DateRangeFilterTests {
    func mkItem(dateTaken: Date?) -> MediaItem {
        MediaItem(path: "/a.jpg", hash: "h", dateTaken: dateTaken, fileType: "image",
                  width: nil, height: nil, lastScanned: Date())
    }

    @Test func inactiveWhenBothBoundsNil() {
        let filter = DateRangeFilter()
        #expect(!filter.isActive)
        #expect(filter.matches(mkItem(dateTaken: Date())))
        #expect(filter.matches(mkItem(dateTaken: nil)))
    }

    @Test func nilDateFailsWhenActive() {
        let filter = DateRangeFilter(lower: Date(timeIntervalSince1970: 0))
        #expect(filter.isActive)
        #expect(!filter.matches(mkItem(dateTaken: nil)))
    }

    @Test func lowerBoundExcludesEarlierDates() {
        let lower = Date(timeIntervalSince1970: 1_000_000)
        let filter = DateRangeFilter(lower: lower)
        #expect(!filter.matches(mkItem(dateTaken: lower.addingTimeInterval(-1))))
        #expect(filter.matches(mkItem(dateTaken: lower)))
        #expect(filter.matches(mkItem(dateTaken: lower.addingTimeInterval(1))))
    }

    @Test func upperBoundExcludesLaterDates() {
        let upper = Date(timeIntervalSince1970: 2_000_000)
        let filter = DateRangeFilter(upper: upper)
        #expect(filter.matches(mkItem(dateTaken: upper)))
        #expect(filter.matches(mkItem(dateTaken: upper.addingTimeInterval(-1))))
        #expect(!filter.matches(mkItem(dateTaken: upper.addingTimeInterval(1))))
    }

    @Test func bothBoundsFormInclusiveWindow() {
        let lower = Date(timeIntervalSince1970: 1_000_000)
        let upper = Date(timeIntervalSince1970: 2_000_000)
        let filter = DateRangeFilter(lower: lower, upper: upper)
        #expect(filter.matches(mkItem(dateTaken: lower)))
        #expect(filter.matches(mkItem(dateTaken: upper)))
        let mid = Date(timeIntervalSince1970: (lower.timeIntervalSince1970 + upper.timeIntervalSince1970) / 2)
        #expect(filter.matches(mkItem(dateTaken: mid)))
        #expect(!filter.matches(mkItem(dateTaken: lower.addingTimeInterval(-1))))
        #expect(!filter.matches(mkItem(dateTaken: upper.addingTimeInterval(1))))
    }
}
