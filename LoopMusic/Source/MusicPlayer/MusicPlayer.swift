import AVFoundation
import CoreAudio
import MediaPlayer

/// Handles playback and looping of music tracks.
class MusicPlayer {
    
    /// The default number of frames to be read from an audio file when loading the initial portion of audio.
    static let START_READ_FRAMES: AVAudioFramePosition = AVAudioFramePosition(1000000)
    /// The number of frames to be read from an audio file each time it is read from asynchronously.
    static let FRAME_READ_INCREMENT: AVAudioFrameCount = AVAudioFrameCount(100000)
    
    /// The amount of time (seconds) between each volume decrement when fading out.
    static let FADE_DECREMENT_TIME: Double = 0.1

    /// The threshold time (seconds) for playback before which rewinding will try to play the previous track, and after which rewinding will just reset the current playback. This is 3 seconds in Apple Music 1.0.5.14.
    static let REWIND_THRESHOLD_TIME: Double = 3

    /// Singleton instance.
    static let player: MusicPlayer = MusicPlayer()
    
    /// The track currently loaded in the music player.
    private(set) var currentTrack: MusicTrack = MusicTrack.BLANK_MUSIC_TRACK
    /// Previous tracks loaded in the music player (including the current one), ordered chronologically.
    private(set) var trackHistory: [MPMediaItem] = []
    /// trackHistory index of the track currently loaded in the music player. Will be -1 if trackHistory is empty (or if the current track was pruned away recently).
    private(set) var trackHistoryIndex: Int = -1
    /// True if the player is currently playing a track.
    private(set) var playing: Bool = false
    /// True if the player is paused.
    private(set) var paused: Bool = false
    /// True if the player is paused because of an interrupt.
    private(set) var interrupted: Bool = false;

    /// Timer used to shuffle tracks after playing for a while.
    private var shuffleTimer: Timer?
    /// Time remaining for the shuffle timer if it was paused.
    private var shuffleTimeRemaining: TimeInterval?

    /// Timer used to fade out tracks before shuffling them.
    private var fadeTimer: Timer?
    
    /// Sample rate of the currently loaded track.
    private(set) var sampleRate: Double = 44100
    
    /// Audio data for the currently playing track.
    private(set) var audioBuffer: AudioBuffer?
    /// True if the current audio track was converted manually.
    private var manuallyAllocatedBuffer: Bool = false
    /// The data type of the loaded audio data.
    private(set) var audioType: AudioType = AudioType.int32
    
    /// Lock to prevent the audio buffer from being loaded and freed at the same time.
    private var bufferLock: DispatchSemaphore = DispatchSemaphore(value: 1)
    /// Passed to the dispatch queue tasks so the audio loading task knows if the track changes while it's still loading.
    private var trackUuid: UUID = UUID()
    
    /// Volume multiplier used when fading out.
    private var fadeMultiplier: Double = 1
    
    /// Audio data necessary for the loop finder.
    var audioData: AudioData {
        get {
            return AudioData(audioBuffer: audioBuffer!, audioType: Int32(audioType.rawValue), numSamples: Int32(numSamples), sampleRate: sampleRate)
        }
    }
    
    /// True if the player has a track loaded in it.
    var trackLoaded: Bool {
        get {
            return currentTrack.url != MusicTrack.BLANK_MUSIC_TRACK.url
        }
    }

    /// The index of the currently playing sample within the audio data.
    var sampleCounter: Int {
        get {
            return Int(getSampleCounter())
        }
        set {
            setSampleCounter(Int64(newValue))
        }
    }
    
    /// The current playback time in seconds.
    var playbackTimeSeconds: Double {
        get {
            return convertSamplesToSeconds(sampleCounter)
        }
        set {
            sampleCounter = convertSecondsToSamples(newValue)
        }
    }

    /// The total number of samples in the audio data.
    var numSamples: Int {
        get {
            return Int(getNumSamples());
        }
    }
    
    /// The length of the audio data in seconds.
    var durationSeconds: Double {
        get {
            return convertSamplesToSeconds(numSamples)
        }
    }

    /// The audio sample to start the loop at.
    var loopStart: Int {
        get {
            return Int(getLoopStart());
        }
        set {
            currentTrack.loopStart = convertSamplesToSeconds(newValue)
            updateLoopPoints()
        }
    }

    /// The audio sample to end the loop at.
    var loopEnd: Int {
        get {
            return Int(getLoopEnd());
        }
        set {
            currentTrack.loopEnd = convertSamplesToSeconds(newValue)
            updateLoopPoints()
        }
    }
    
    /// The number of seconds to start the loop at.
    var loopStartSeconds: Double {
        get {
            return currentTrack.loopStart
        }
        set {
            currentTrack.loopStart = newValue
            updateLoopPoints()
        }
    }
    
    /// The number of seconds to end the loop at.
    var loopEndSeconds: Double {
        get {
            return currentTrack.loopEnd
        }
        set {
            currentTrack.loopEnd = newValue
            updateLoopPoints()
        }
    }
    
    /// Whether loop times are used to loop playback.
    var loopPlayback: Bool {
        get {
            return Bool(getLoopPlayback())
        }
        set {
            setLoopPlayback(newValue)
        }
    }

    var volumeMultiplier: Double {
        get {
            return currentTrack.volumeMultiplier
        }
        set {
            currentTrack.volumeMultiplier = newValue
            updateVolume()
        }
    }
    
    /// Sets up audio playback.
    func initialize() throws {
        try enableBackgroundAudio()
    }
    
    /// Loads a track into the music player.
    /// - parameter mediaItem: The audio track to play.
    /// - parameter updateHistory: Whether or not to record the loaded track in the player's history (including updating the history index). Defaults to true.
    func loadTrack(mediaItem: MPMediaItem, updateHistory: Bool = true) throws {
        try stopTrack()
        
        // Unload the buffer for the previous track.
        bufferLock.wait()
        if let audioBuffer: AudioBuffer = audioBuffer {
            free(audioBuffer.mData)
        }
        trackUuid = UUID()
        bufferLock.signal()
        
        currentTrack = try MusicData.data.loadTrack(mediaItem: mediaItem)
        /// Audio file containing the track to load.
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: currentTrack.url)
        } catch {
            throw MessageError("Failed to read audio file.", error)
        }
        
        /// Initial number of audio frames to read before starting audio playback.
        let startReadFrames: AVAudioFrameCount = AVAudioFrameCount(min(audioFile.length, MusicPlayer.START_READ_FRAMES))
        guard let origBuffer: AVAudioPCMBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: startReadFrames) else {
            throw MessageError("Audio is not in PCM format.")
        }
        
        /// Pointer to the audio file's audio description.
        let origAudioDescPointer: UnsafePointer<AudioStreamBasicDescription> = audioFile.processingFormat.streamDescription
        /// Audio file's audio description.
        let origAudioDesc: AudioStreamBasicDescription = origAudioDescPointer.pointee
        /// Audio description for the track to play, including interleaved conversion.
        var audioDesc: AudioStreamBasicDescription = origAudioDesc
        
        /// True if the audio is non-interleaved.
        let noninterleaved: Bool = origAudioDesc.mFormatFlags & kAudioFormatFlagIsNonInterleaved > 0
        /// Audio converter to convert non-interleaved audio.
        var converter: AudioConverterRef?
        /// Audio description for the converted audio if non-interleaved is converted to interleaved. Initialized outside the if clause to prevent deallocation.
        var convertedAudioDesc: AudioStreamBasicDescription = AudioStreamBasicDescription()
        // If the audio data is non-interleaved, it needs to be converted to interleaved format to be streamed.
        if noninterleaved {
            convertedAudioDesc.mSampleRate = origAudioDesc.mSampleRate
            convertedAudioDesc.mFormatID = origAudioDesc.mFormatID
            convertedAudioDesc.mBitsPerChannel = origAudioDesc.mBitsPerChannel
            convertedAudioDesc.mChannelsPerFrame = origAudioDesc.mChannelsPerFrame
            convertedAudioDesc.mFramesPerPacket = origAudioDesc.mFramesPerPacket
            convertedAudioDesc.mReserved = origAudioDesc.mReserved
            
            convertedAudioDesc.mFormatFlags = origAudioDesc.mFormatFlags & ~kAudioFormatFlagIsNonInterleaved
            // Interleaved audio combines all channels in the same frame, different from non-interleaved audio.
            convertedAudioDesc.mBytesPerFrame = origAudioDesc.mBytesPerFrame * convertedAudioDesc.mChannelsPerFrame
            convertedAudioDesc.mBytesPerPacket = convertedAudioDesc.mBytesPerFrame * convertedAudioDesc.mFramesPerPacket
            
            audioDesc = convertedAudioDesc
            
            /// Pointer to the non-interleaved audio converter.
            let converterPointer: UnsafeMutablePointer<AudioConverterRef?> = UnsafeMutablePointer<AudioConverterRef?>.allocate(capacity: MemoryLayout<AudioConverterRef>.size)
            /// Status code for creating an audio converter.
            let createStatus: OSStatus = AudioConverterNew(origAudioDescPointer, UnsafePointer(&audioDesc), converterPointer)
            if createStatus != 0 {
                throw MessageError("Failed to create converter for interleaved audio.", createStatus)
            }
            converter = converterPointer.pointee
        }
        
        do {
            try audioFile.read(into: origBuffer, frameCount: startReadFrames)
        } catch {
            throw MessageError("Failed to load audio file into buffer.", error)
        }
        
        /// Size of the audio buffer in bytes.
        let bufferSize: UInt32 = audioDesc.mBytesPerFrame * UInt32(audioFile.length)
        audioBuffer = AudioBuffer(mNumberChannels: audioDesc.mChannelsPerFrame, mDataByteSize: bufferSize, mData: malloc(Int(bufferSize)))
        
        try convertAndAddAudio(origBuffer: origBuffer, audioDesc: audioDesc, converter: converter, noninterleaved: noninterleaved, offset: 0)
        
        /// Status code for loading audio into the music player.
        var loadStatus: OSStatus = -1
        /// Number of frames in the audio file across all channels.
        let audioLength: AVAudioFramePosition = audioFile.length * Int64(audioDesc.mChannelsPerFrame)
        sampleRate = audioDesc.mSampleRate
        
        let audioData: UnsafeMutableRawPointer = audioBuffer!.mData!
        // Check for the data type of the audio and load it in the audio engine accordingly.
        if origBuffer.int32ChannelData != nil {
            loadStatus = load32BitAudio(audioData, audioLength, audioDesc)
            audioType = AudioType.int32
        } else if origBuffer.int16ChannelData != nil {
            loadStatus = load16BitAudio(audioData, audioLength, audioDesc)
            audioType = AudioType.int16
        } else if origBuffer.floatChannelData != nil {
            loadStatus = loadFloatAudio(audioData, audioLength, audioDesc)
            audioType = AudioType.float
        }
        
        if loadStatus != 0 {
            throw MessageError("Audio data is empty or not supported.", loadStatus)
        }
        
        try loadAudioAsync(audioFile: audioFile, loadBuffer: origBuffer, audioDesc: audioDesc, converter: converter, noninterleaved: noninterleaved, currentFramesRead: startReadFrames, processUuid: trackUuid)

        // Update track history queue if specified.
        if updateHistory {
            // Only add to the history if the loaded track is not already the most recent in history.
            if trackHistory.last == nil || mediaItem != trackHistory.last! {
                rememberTrack(track: mediaItem)
            }
            trackHistoryIndex = trackHistory.count - 1
        }

        if currentTrack.loopEnd == 0 {
            currentTrack.loopEnd = durationSeconds
        }
        updateLoopPoints()
        
        try playTrack()
        
        NotificationCenter.default.post(name: .changeTrack, object: nil)
    }
    
    /// Adds the next portion of audio to the audio buffer. Converts non-interleaved to interleaved audio if necessary.
    /// - parameter origBuffer: Audio buffer to get audio data from.
    /// - parameter audioDesc: Audio description of the audio file.
    /// - parameter converter: Audio converter to convert non-interleaved audio.
    /// - parameter noninterleaved: True if the audio is non-interleaved.
    /// - parameter offset: Offset for inserting converted data into the class-level audio buffer.
    private func convertAndAddAudio(origBuffer: AVAudioPCMBuffer, audioDesc: AudioStreamBasicDescription, converter: AudioConverterRef?, noninterleaved: Bool, offset: Int) throws {
        if noninterleaved {
            try convertToInterleavedAudio(origBuffer: origBuffer, audioDesc: audioDesc, converter: converter!, offset: offset)
        } else {
            addToAudioBuffer(buffer: origBuffer.audioBufferList.pointee.mBuffers, offset: offset)
            print("Warning: Interleaved audio is untested.")
        }
    }
    
    /// Takes noninterleaved audio data from a buffer and converts it to interleaved audio data. This data is stored in the class-level audio buffer.
    /// - parameter origBuffer: Noninterleaved audio buffer to get audio data from.
    /// - parameter audioDesc: Audio description for the converted audio data.
    /// - parameter converter: Audio converter to convert audio data with.
    /// - parameter offset: Offset for inserting converted data into the class-level audio buffer.
    private func convertToInterleavedAudio(origBuffer: AVAudioPCMBuffer, audioDesc: AudioStreamBasicDescription, converter: AudioConverterRef, offset: Int) throws {
        /// Internal audio buffer list from the audio buffer.
        let origAudioBuffer: AudioBufferList = origBuffer.audioBufferList.pointee
        // Allocate memory for a buffer to store the converted audio data.
        // Combine all buffers from the non-interleaved audio into a single buffer.
        /// Audio buffer list to store converted interleaved audio in.
        let newAudioBufferList: UnsafeMutableAudioBufferListPointer = AudioBufferList.allocate(maximumBuffers: 1)
        /// Size of the converted audio buffer in bytes.
        let newBufferSize: UInt32 = origAudioBuffer.mBuffers.mDataByteSize * origAudioBuffer.mNumberBuffers

        /// Audio buffer to store converted interleaved audio in.
        let newAudioBuffer: AudioBuffer = AudioBuffer(mNumberChannels: audioDesc.mChannelsPerFrame, mDataByteSize: newBufferSize, mData: malloc(Int(newBufferSize)))
        newAudioBufferList[0] = newAudioBuffer
    
        /// Status code from audio converter for interleaved audio.
        let convertStatus: OSStatus = AudioConverterConvertComplexBuffer(converter, origBuffer.frameLength, origBuffer.audioBufferList, newAudioBufferList.unsafeMutablePointer)
        if convertStatus != 0 {
            throw MessageError("Failed to convert to interleaved audio.", convertStatus)
        }
        
        addToAudioBuffer(buffer: newAudioBuffer, offset: offset)
        free(newAudioBuffer.mData)
    }
    
    /// Transfers audio data from an audio buffer to the class-level audio buffer.
    /// - parameter buffer: Audio buffer to transfer data from.
    /// - parameter offset: Offset for inserting data into the class-level audio buffer.
    private func addToAudioBuffer(buffer: AudioBuffer, offset: Int) {
        /// Memory address to start copying audio data into the class-level buffer.
        let dataOffset: UnsafeMutableRawPointer = audioBuffer!.mData! + offset
        dataOffset.copyMemory(from: buffer.mData!, byteCount: Int(buffer.mDataByteSize))
    }
    
    /// Loads the next portion of audio asynchronously from the main thread.
    /// - parameter audioFile: The audio file being loaded.
    /// - parameter loadBuffer: Audio buffer to load audio samples into.
    /// - parameter audioDesc: Audio description of the audio file.
    /// - parameter converter: Audio converter to convert non-interleaved audio.
    /// - parameter noninterleaved: True if the audio is non-interleaved.
    /// - parameter currentFramesRead: The number of audio frames that have been read so far.
    /// - parameter processUuid: The UUID of the audio track process. If the track changes, this will not match and the async task will cancel.
    private func loadAudioAsync(audioFile: AVAudioFile, loadBuffer: AVAudioPCMBuffer, audioDesc: AudioStreamBasicDescription, converter: AudioConverterRef?, noninterleaved: Bool, currentFramesRead: AVAudioFrameCount, processUuid: UUID) throws {
        if currentFramesRead >= audioFile.length {
            try disposeConverter(converter: converter)
            return
        }
        DispatchQueue.global(qos: DispatchQoS.background.qosClass).async {
            do {
                try audioFile.read(into: loadBuffer, frameCount: MusicPlayer.FRAME_READ_INCREMENT)

                self.bufferLock.wait()
                if processUuid == self.trackUuid {
                    try self.convertAndAddAudio(origBuffer: loadBuffer, audioDesc: audioDesc, converter: converter, noninterleaved: noninterleaved, offset: Int(currentFramesRead * audioDesc.mBytesPerFrame))
                    self.bufferLock.signal()
                } else {
                    // If the process UUID doesn't match, the track has changed. Cancel loading the audio.
                    self.bufferLock.signal()
                    try self.disposeConverter(converter: converter)
                    return
                }
            
                // Recursively load audio until the file is fully read.
                try self.loadAudioAsync(audioFile: audioFile, loadBuffer: loadBuffer, audioDesc: audioDesc, converter: converter, noninterleaved: noninterleaved, currentFramesRead: currentFramesRead + MusicPlayer.FRAME_READ_INCREMENT, processUuid: processUuid)
            } catch {
                print("Error loading audio asynchronously:", error.localizedDescription)
                return
            }
        }
    }
    
    /// Adds the next portion of audio to the audio buffer.
    /// - parameter loadBuffer: Audio buffer to load audio samples into.
    /// - parameter audioDesc: Audio description of the audio file.
    /// - parameter converter: Audio converter to convert non-interleaved audio.
    /// - parameter noninterleaved: True if the audio is non-interleaved.
    /// - parameter currentFramesRead: The number of audio frames that have been read so far.
    /// - parameter processUuid: The UUID of the audio track process. If the track changes, this will not match and the async task will cancel.
    private func addAudioAsync(loadBuffer: AVAudioPCMBuffer, audioDesc: AudioStreamBasicDescription, converter: AudioConverterRef?, noninterleaved: Bool, currentFramesRead: AVAudioFrameCount, processUuid: UUID) throws {
        defer { bufferLock.signal() }
        if processUuid == self.trackUuid {
            try self.convertAndAddAudio(origBuffer: loadBuffer, audioDesc: audioDesc, converter: converter, noninterleaved: noninterleaved, offset: Int(currentFramesRead * audioDesc.mBytesPerFrame))
        } else {
            // If the process UUID doesn't match, the track has changed. Cancel loading the audio.
            try self.disposeConverter(converter: converter)
        }
    }
    
    /// Disposes an audio converter.
    /// - parameter converter: The converter to dispose.
    private func disposeConverter(converter: AudioConverterRef?) throws {
        if let converter: AudioConverterRef = converter {
            /// Status code for disposing the audio converter.
            let deallocateStatus: OSStatus = AudioConverterDispose(converter)
            if deallocateStatus != 0 {
                throw MessageError("Failed to deallocate converter for interleaved audio.", deallocateStatus)
            }
        }
    }
    
    /// Starts playing the currently loaded track (or resumes it, if paused).
    func playTrack() throws {
        if !playing {
            resetFadeVolume()
            playing = true
            paused = false;
            interrupted = false;
            /// Status code for playing audio.
            let playStatus: OSStatus = playAudio()
            if playStatus != 0 {
                throw MessageError("Failed to play audio.", playStatus)
            }
            startShuffleTimer()
        }
    }
    
    /// Pauses playback of the currently loaded track.
    /// - parameter interrupted: True if the pause comes from an interrupt.
    func pauseTrack(interrupted: Bool) throws {
        if playing {
            playing = false
            paused = true
            self.interrupted = interrupted
            pauseShuffleTimer()
            /// Status code for pausing audio.
            let pauseStatus: OSStatus = pauseAudio()
            if pauseStatus != 0 {
                throw MessageError("Failed to pause audio.", pauseStatus)
            }
        }
    }

    /// Stops playing the currently loaded track and resets playback.
    func stopTrack() throws {
        if playing || paused {
            playing = false
            paused = false
            interrupted = false
            stopShuffleTimer()
            /// Status code for stopping audio.
            let stopStatus: OSStatus = stopAudio()
            if stopStatus != 0 {
                throw MessageError("Failed to stop audio.", stopStatus)
            }
        }
    }
    
    /// Updates the loop start/end within the audio engine.
    private func updateLoopPoints() {
        setLoopPoints((Int64) (convertSecondsToSamples(currentTrack.loopStart)), (Int64) (convertSecondsToSamples(currentTrack.loopEnd)))
    }
    
    /// Updates the volume multiplier within the audio engine.
    func updateVolume() {
        setVolumeMultiplier(currentTrack.volumeMultiplier * MusicSettings.settings.masterVolume * fadeMultiplier)
    }
    
    /// Saves the currently configured volume multiplier to the database.
    func saveVolumeMultiplier() throws {
        try MusicData.data.updateVolumeMultiplier(track: currentTrack)
    }
    
    /// Saves the currently configured loop points to the database.
    func saveLoopPoints() throws {
        try MusicData.data.updateLoopPoints(track: currentTrack)
    }
    
    /// Prune the oldest entries in the track history queue if the queue is above maximum capacity.
    func pruneTrackHistory() {
        // It should be, like, doubly-impossible for this setting to be negative...but max it with 0 just in case.
        let historyLength = max(0, MusicSettings.settings.shuffleHistoryLength ?? 0)
        let numToRemove = max(0, trackHistory.count - historyLength)
        trackHistory.removeFirst(numToRemove)
        // Also need to shift the index back by the number removed. But make sure it doesn't go below -1. -1 means the current index was pruned, and loading the next track should load the first in the queue.
        trackHistoryIndex = max(-1, trackHistoryIndex - numToRemove)
    }

    /// Push a new track onto the track history queue, and remove the oldest entries if above maximum capacity.
    private func rememberTrack(track: MPMediaItem) {
        if (MusicSettings.settings.shuffleHistoryLength ?? 0) > 0 {
            trackHistory.append(track)
        }
        pruneTrackHistory()
    }

    /// Chooses a random track from the current playlist and starts playing it.
    func randomizeTrack() throws {
        /// Tracks list to randomly choose from.
        var tracks: [MPMediaItem] = MediaPlayerUtils.getTracksInPlaylist()
        /// Tracks that haven't been played recently.
        let newTracks: [MPMediaItem] = tracks.filter { !trackHistory.contains($0) }
        
        /// Pick from new tracks if possible, otherwise fall back to the full track list.
        if newTracks.count > 0 {
            tracks = newTracks
        } else if tracks.count > 1 && trackHistory.count > 0 {
            // If possible, at least try to avoid an immediate repeat.
            tracks = tracks.filter { $0 != trackHistory.last! }
        }
        if tracks.count == 0 {
            throw MessageError("No compatible tracks found.")
        }
        
        /// Randomly chosen track to play.
        let randomTrack: MPMediaItem = tracks.randomElement()!

        try loadTrack(mediaItem: randomTrack)
        try playTrack()
    }

    /// Loads the next track in recent memory. If there is no next track, picks a random one.
    func loadNextTrack() throws {
        // Preserve the current play/pause state.
        let wasPlaying = playing

        if trackHistoryIndex < trackHistory.count - 1 {
            trackHistoryIndex += 1
            try loadTrack(mediaItem: trackHistory[trackHistoryIndex], updateHistory: false)
            try playTrack()
        } else {
            // No new tracks; pick a random new one.
            try randomizeTrack()
        }

        if !wasPlaying {
            try stopTrack()
        }
    }

    /// Loads the previous track in recent memory. If there isn't one, throw an error.
    func loadPreviousTrack() throws {
        // Preserve the current play/pause state.
        let wasPlaying = playing

        if trackHistoryIndex > 0 {
            trackHistoryIndex -= 1
            try loadTrack(mediaItem: trackHistory[trackHistoryIndex], updateHistory: false)
            try playTrack()
        } else {
            throw MessageError("No previous tracks to play.")
        }

        if !wasPlaying {
            try stopTrack()
        }
    }

    /// If the playback time is before a certain threshold and there are previous tracks in recent memory, play the previous track. Otherwise, reset playback.
    func rewind() throws {
        if playbackTimeSeconds < MusicPlayer.REWIND_THRESHOLD_TIME && trackHistoryIndex > 0 {
            try loadPreviousTrack()
        } else {
            // Preserve the current play state
            let wasPlaying = playing
            try stopTrack()
            if wasPlaying {
                try playTrack()
            }
        }
    }

    /// Reloads all tracks in the current playlist. Used for database migration.
    func reloadAllTracks() throws {
        /// Tracks list to load.
        let tracks: [MPMediaItem] = MediaPlayerUtils.getTracksInPlaylist()
        
        try tracks.forEach { track in
            try loadTrack(mediaItem: track, updateHistory: false)
        }
    }
    
    /// Enables background audio playback for the app.
    private func enableBackgroundAudio() throws {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            throw MessageError("Error enabling background audio.", error)
        }
    }
    
    /// Starts the timer used to shuffle tracks (or resumes it, if paused).
    func startShuffleTimer() {
        if shuffleTimer != nil {
            rawStopShuffleTimer()
        }
        if let shuffleTime: Double = shuffleTimeRemaining ?? MusicSettings.settings.calculateShuffleTime(track: currentTrack) {
            shuffleTimer = Timer.scheduledTimer(withTimeInterval: shuffleTime, repeats: false) { [weak self] _ in
                do {
                    if let fadeDuration: Double = MusicSettings.settings.fadeDuration {
                        if fadeDuration > 0 {
                            self?.fadeTimer = Timer.scheduledTimer(withTimeInterval: MusicPlayer.FADE_DECREMENT_TIME, repeats: true) { [weak self] _ in
                                do {
                                    guard let self = self else { return }
                                    self.fadeMultiplier = max(0, self.fadeMultiplier - MusicPlayer.FADE_DECREMENT_TIME / fadeDuration)
                                    self.updateVolume()
                                    if self.fadeMultiplier <= 0 {
                                        try self.loadNextTrack()
                                    }
                                } catch {
                                    print("Error loading next track:", error.localizedDescription)
                                }
                            }
                            return
                        }
                    }
                    try self?.loadNextTrack()
                } catch {
                    print("Error loading next track:", error.localizedDescription)
                }
            }
        }
    }
    
    /// Stops the timer used to shuffle tracks without clearing the shuffleTimeRemaining field.
    private func rawStopShuffleTimer() {
        shuffleTimer?.invalidate()
        shuffleTimer = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        if playing {
            resetFadeVolume()
        }
    }
    
    /// Stops the timer used to shuffle tracks.
    func stopShuffleTimer() {
        rawStopShuffleTimer()
        shuffleTimeRemaining = nil
    }

    /// Pauses the timer used to shuffle tracks.
    func pauseShuffleTimer() {
        // Record the remaining time before invalidating the timer.
        if let timeRemaining = shuffleTimer?.fireDate.timeIntervalSinceNow {
            // Max with 0 just in case...
            shuffleTimeRemaining = max(0, timeRemaining)
        }
        rawStopShuffleTimer()
    }

    /// Converts a sample number into seconds using the current sample rate.
    /// - parameter samples: The number of samples to convert.
    /// - returns: The given samples converted to seconds.
    func convertSamplesToSeconds(_ samples: Int) -> Double {
        return Double(samples) / sampleRate
    }
    
    /// Converts a seconds value into a sample number using the current sample rate.
    /// - parameter seconds: The seconds value to convert.
    /// - returns: The given seconds converted to samples.
    func convertSecondsToSamples(_ seconds: Double) -> Int {
        return Int(round(seconds * sampleRate))
    }

    /// Resets the fade effect.
    private func resetFadeVolume() {
        fadeMultiplier = 1
        updateVolume()
    }
}
