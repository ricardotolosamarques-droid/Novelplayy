package com.codenexus.novelix

data class Drama(
    val id: String, val title: String, val description: String = "",
    val coverUrl: String? = null, val episodeCount: Int = 0, val genre: String = "Drama"
)
data class Episode(
    val id: String, val number: Int, val isPlayable: Boolean = false,
    val requiresEntitlement: Boolean = false, val streamUrl: String? = null
)
data class PlaybackResponse(val streamUrl: String, val expiresAt: String? = null)
data class HomeResponse(val items: List<Drama> = emptyList())
data class EpisodesResponse(val items: List<Episode> = emptyList())
