package com.codenexus.novelix

import retrofit2.Retrofit
import retrofit2.converter.gson.GsonConverterFactory
import retrofit2.http.GET
import retrofit2.http.Path
import retrofit2.http.Query

/**
 * Configure NOVELIX_API_BASE_URL with YOUR authorized content-provider URL.
 * The provider contract below is an adapter contract, not an official ReelShort API.
 */
interface NovelixApi {
    @GET("v1/reelshort/home") suspend fun home(): HomeResponse
    @GET("v1/reelshort/search") suspend fun search(@Query("q") query: String): HomeResponse
    @GET("v1/reelshort/dramas/{id}/episodes")
    suspend fun episodes(@Path("id") id: String): EpisodesResponse
    @GET("v1/reelshort/episodes/{id}/playback")
    suspend fun playback(@Path("id") id: String): PlaybackResponse
}

object ApiFactory {
    // Replace with your own backend. Keep provider secrets on the server, never in the APK.
    private const val BASE_URL = "https://YOUR-AUTHORIZED-API.example/"
    val api: NovelixApi by lazy {
        Retrofit.Builder().baseUrl(BASE_URL)
            .addConverterFactory(GsonConverterFactory.create()).build()
            .create(NovelixApi::class.java)
    }
}
