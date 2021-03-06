import UIKit

/// Finds loop points.
class LoopFinder {
    
    let loopFinderAuto: LoopFinderAuto = LoopFinderAuto()
    
    /// Whether or not to use an initial start estimate when looking for loop points.
    var useInitialStartEstimate: Bool = false
    /// Whether or not to use an initial end estimate when looking for loop points.
    var useInitialEndEstimate: Bool = false

    /// Cached loop results.
    var loopDurationsCache: [LoopDuration]?
    /// Cached initial start estimate.
    var t1EstimateCache: Float?
    /// Cached initial end estimate.
    var t2EstimateCache: Float?

    /// Finds loop points for the current track.
    func findLoopPoints() -> [LoopDuration] {
        /// Loop finder instance for automatically finding a loop.
        let settingsChanged = MusicSettings.settings.customizeLoopFinder(loopFinder: loopFinderAuto)
        /// Feed initial estimates into the loop finder if configured.
        loopFinderAuto.t1Estimate = useInitialStartEstimate ? Float(MusicPlayer.player.loopStartSeconds) : -1
        loopFinderAuto.t2Estimate = useInitialEndEstimate ? Float(MusicPlayer.player.loopEndSeconds) : -1

        // If there's an old result cached and no config has changed, just return the cache.
        if let oldLoopDurations = loopDurationsCache, let oldT1Estimate = t1EstimateCache, let oldT2Estimate = t2EstimateCache {
            if loopFinderAuto.t1Estimate == oldT1Estimate && loopFinderAuto.t2Estimate == oldT2Estimate && !settingsChanged {
                return oldLoopDurations
            }
        }
        // Cache initial estimate config for comparing with subsequent runs.
        t1EstimateCache = loopFinderAuto.t1Estimate
        t2EstimateCache = loopFinderAuto.t2Estimate

        /// Audio data for the currently playing track.
        var audioData: AudioData = MusicPlayer.player.audioData
        
        /// Durations and loop points found by the loop finder.
        let durationsRaw: [AnyHashable : Any] = loopFinderAuto.findLoop(&audioData)
        
        /// Duration lengths from the loop finder.
        let baseDurations: NSArray = durationsRaw["baseDurations"] as! NSArray
        /// Duration lengths from the loop finder.
        let confidences: NSArray = durationsRaw["confidences"] as! NSArray
        /// Loop start times from the loop finder.
        let startFrames: NSArray = durationsRaw["startFrames"] as! NSArray
        /// Loop end times from the loop finder.
        let endFrames: NSArray = durationsRaw["endFrames"] as! NSArray
        
        /// Loop durations extracted from the loop finder results.
        var loopDurations: [LoopDuration] = []
        
        for i in 0..<baseDurations.count {
            /// Loop endpoints extracted from the loop finder results.
            var loopEndpoints: [LoopEndpoints] = []
            /// Loop start times for the current duration.
            let durationStartFrames: NSArray = startFrames[i] as! NSArray
            /// Loop end times for the current duration.
            let durationEndFrames: NSArray = endFrames[i] as! NSArray
            for j in 0..<durationStartFrames.count {
                loopEndpoints.append(LoopEndpoints(rank: j + 1, start: durationStartFrames[j] as! Int, end: durationEndFrames[j] as! Int))
            }
            
            loopDurations.append(LoopDuration(rank: i + 1, confidence: (confidences[i] as! Double), duration: baseDurations[i] as! Int, endpoints: loopEndpoints))
        }
        
        // Cache results.
        loopDurationsCache = loopDurations

        return loopDurations
    }
    
    /// Releases cached memory used by the loop finder.
    func destroy() {
        loopFinderAuto.performFFTDestroy()
    }
}
