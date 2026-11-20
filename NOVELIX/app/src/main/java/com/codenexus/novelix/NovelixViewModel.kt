package com.codenexus.novelix

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class ScreenState(
    val dramas: List<Drama> = demoDramas,
    val episodes: List<Episode> = emptyList(),
    val loading: Boolean = false,
    val error: String? = "Modo demonstração: configure um provedor de conteúdo autorizado para carregar o catálogo."
)

private val demoDramas = listOf(
    Drama("demo-1", "Contrato com o Bilionário", "Um acordo inesperado muda o destino de duas pessoas. Configure a API para carregar a sinopse oficial.", null, 48, "Romance"),
    Drama("demo-2", "A Herdeira Disfarçada", "Uma jovem esconde sua identidade e retorna para acertar as contas.", null, 62, "Vingança"),
    Drama("demo-3", "Meu Chefe Secreto", "Um novo emprego guarda uma surpresa que ninguém imaginava.", null, 36, "Romance")
)

class NovelixViewModel : ViewModel() {
    private val _state = MutableStateFlow(ScreenState())
    val state = _state.asStateFlow()

    fun refresh() = viewModelScope.launch {
        _state.value = _state.value.copy(loading = true, error = null)
        runCatching { ApiFactory.api.home() }
            .onSuccess { _state.value = _state.value.copy(dramas = it.items, loading = false) }
            .onFailure { _state.value = _state.value.copy(loading = false, error = "API não configurada ou indisponível: ${it.message}") }
    }

    fun search(query: String) = viewModelScope.launch {
        if (query.isBlank()) { refresh(); return@launch }
        _state.value = _state.value.copy(loading = true)
        runCatching { ApiFactory.api.search(query) }
            .onSuccess { _state.value = _state.value.copy(dramas = it.items, loading = false, error = null) }
            .onFailure { _state.value = _state.value.copy(loading = false, error = "Falha na busca: ${it.message}") }
    }

    fun loadEpisodes(dramaId: String) = viewModelScope.launch {
        _state.value = _state.value.copy(loading = true, episodes = emptyList())
        runCatching { ApiFactory.api.episodes(dramaId) }
            .onSuccess { _state.value = _state.value.copy(episodes = it.items, loading = false) }
            .onFailure { _state.value = _state.value.copy(loading = false, error = "Não foi possível carregar episódios. Configure a API.") }
    }

    fun requestPlayback(episode: Episode, onReady: (Episode) -> Unit) = viewModelScope.launch {
        // Entitlement is enforced by the provider. The app never flips a paid episode to free.
        if (episode.requiresEntitlement) {
            _state.value = _state.value.copy(error = "Este episódio exige uma autorização/assinatura válida no provedor.")
            return@launch
        }
        runCatching { ApiFactory.api.playback(episode.id) }
            .onSuccess { onReady(episode.copy(isPlayable = true, streamUrl = it.streamUrl)) }
            .onFailure { _state.value = _state.value.copy(error = "Reprodução indisponível: ${it.message}") }
    }
}
