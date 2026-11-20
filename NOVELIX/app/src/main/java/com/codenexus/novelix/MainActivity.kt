package com.codenexus.novelix

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.*
import androidx.lifecycle.viewmodel.compose.viewModel
import coil.compose.AsyncImage

private val Ink = Color(0xFF090A0F)
private val Panel = Color(0xFF171923)
private val Accent = Color(0xFFFF375F)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme(colorScheme = darkColorScheme(
            background = Ink, surface = Panel, primary = Accent, onBackground = Color.White,
            onSurface = Color.White
        )) { NovelixApp() } }
    }
}

@Composable
fun NovelixApp(vm: NovelixViewModel = viewModel()) {
    val state by vm.state.collectAsState()
    var query by remember { mutableStateOf("") }
    var selected by remember { mutableStateOf<Drama?>(null) }
    var playing by remember { mutableStateOf<Episode?>(null) }
    Scaffold(containerColor = Ink, bottomBar = {
        NavigationBar(containerColor = Panel) {
            NavigationBarItem(selected = selected == null, onClick = { selected = null; playing = null },
                icon = { Icon(Icons.Default.Home, null) }, label = { Text("Início") })
            NavigationBarItem(selected = false, onClick = { vm.refresh() },
                icon = { Icon(Icons.Default.Refresh, null) }, label = { Text("Atualizar") })
        }
    }) { pad ->
        Column(Modifier.fillMaxSize().padding(pad)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Text("NOVA", color = Accent, fontSize = 25.sp, fontWeight = FontWeight.Black)
                Text("LIX", color = Color.White, fontSize = 25.sp, fontWeight = FontWeight.Black)
                Spacer(Modifier.weight(1f))
                Icon(Icons.Default.Person, null, tint = Color.LightGray)
            }
            if (playing != null) {
                PlayerScreen(episode = playing!!, onBack = { playing = null })
            } else if (selected != null) {
                DramaScreen(drama = selected!!, episodes = state.episodes,
                    loading = state.loading, onBack = { selected = null },
                    onEpisode = { ep ->
                        if (ep.isPlayable && !ep.streamUrl.isNullOrBlank()) playing = ep
                        else vm.requestPlayback(ep) { result -> playing = result }
                    })
            } else {
                OutlinedTextField(value = query, onValueChange = { query = it; vm.search(it) },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    placeholder = { Text("Buscar novelinhas...") }, leadingIcon = { Icon(Icons.Default.Search, null) },
                    singleLine = true, shape = RoundedCornerShape(16.dp))
                if (state.error != null) Text(state.error!!, color = Color(0xFFFF9AAE),
                    modifier = Modifier.padding(16.dp), fontSize = 12.sp)
                Text(if (query.isBlank()) "Em alta agora" else "Resultados",
                    modifier = Modifier.padding(start = 18.dp, top = 18.dp, bottom = 10.dp),
                    fontSize = 20.sp, fontWeight = FontWeight.Bold)
                if (state.loading) LinearProgressIndicator(Modifier.fillMaxWidth(), color = Accent)
                LazyColumn(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 20.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(state.dramas) { drama ->
                        DramaCard(drama) { selected = drama; vm.loadEpisodes(drama.id) }
                    }
                }
            }
        }
    }
}

@Composable
private fun DramaCard(drama: Drama, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().background(Panel, RoundedCornerShape(16.dp))
        .clickable(onClick = onClick).padding(10.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        AsyncImage(model = drama.coverUrl, contentDescription = drama.title,
            modifier = Modifier.size(width = 104.dp, height = 138.dp))
        Column(Modifier.weight(1f).height(138.dp), verticalArrangement = Arrangement.SpaceBetween) {
            Column {
                Text(drama.title, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                Spacer(Modifier.height(5.dp))
                Text(drama.description, color = Color.LightGray, fontSize = 12.sp, maxLines = 4)
            }
            Text("${drama.episodeCount} episódios  ·  ${drama.genre}",
                color = Accent, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun DramaScreen(drama: Drama, episodes: List<Episode>, loading: Boolean,
                        onBack: () -> Unit, onEpisode: (Episode) -> Unit) {
    Column(Modifier.fillMaxSize()) {
        Text("‹  Voltar", Modifier.clickable { onBack() }.padding(16.dp), color = Accent)
        AsyncImage(model = drama.coverUrl, contentDescription = null,
            modifier = Modifier.fillMaxWidth().height(190.dp))
        Text(drama.title, Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Text(drama.description, Modifier.padding(horizontal = 16.dp),
            color = Color.LightGray, fontSize = 13.sp)
        Text("EPISÓDIOS", Modifier.padding(16.dp), color = Accent, fontWeight = FontWeight.Bold)
        if (loading) LinearProgressIndicator(Modifier.fillMaxWidth(), color = Accent)
        LazyColumn {
            items(episodes) { ep ->
                Row(Modifier.fillMaxWidth().clickable { onEpisode(ep) }.padding(horizontal = 18.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.PlayCircle, null, tint = Accent)
                    Text("  Episódio ${ep.number}", Modifier.weight(1f))
                    Text(if (ep.isPlayable) "Assistir" else if (ep.requiresEntitlement) "Premium" else "Indisponível",
                        color = if (ep.isPlayable) Accent else Color.Gray, fontSize = 12.sp)
                }
                HorizontalDivider(color = Panel)
            }
        }
    }
}

@Composable
private fun PlayerScreen(episode: Episode, onBack: () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        Text("‹  Voltar aos episódios", Modifier.clickable { onBack() }.padding(16.dp), color = Accent)
        AndroidVideoPlayer(url = episode.streamUrl!!)
        Text("Episódio ${episode.number}", Modifier.padding(16.dp),
            fontSize = 20.sp, fontWeight = FontWeight.Bold)
    }
}
