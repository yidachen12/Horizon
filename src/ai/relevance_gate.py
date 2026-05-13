"""Topic-relevance gate — drops off-topic items before AI scoring.

Sits between fetch/merge and the main analyzer. For each item, asks the AI
client to score 0-10 how relevant it is to a single user-defined topic. Items
below the configured threshold are dropped, which saves a lot of money when
broad-source feeds (general game-dev, industry news) get mixed with
narrow-topic feeds (game audio).

The gate reuses the main AI client; no separate config or API key needed.
"""

import asyncio
import re
from typing import List

from ..models import ContentItem, RelevanceGateConfig
from .client import AIClient

# Topic and rubric are inlined into the prompt at call time. We deliberately
# describe both "in scope" and "out of scope" so the model has clear anchors,
# and demand a bare integer back so parsing is trivial.
_PROMPT_TEMPLATE = """判断以下条目与「{topic}」的相关性。

按 0-10 评分：
- 10：直接讲该主题
- 7-9：相关领域且主题内容明确
- 4-6：边缘相关
- 0-3：不相关

只输出一个整数（0-10），不要任何其他文字。

标题：{title}
摘要：{summary}
来源：{source}
"""

# When the topic is "game audio" we inject extra context to make the rubric
# concrete. Keep this concise — long rubrics make the model verbose.
_GAME_AUDIO_HINT = (
    "相关包括：音效设计、音频中间件（Wwise/FMOD/MetaSounds）、游戏音频实现、"
    "程序化音频、游戏音频访谈/招聘/行业人事变动、游戏音乐系统、空间音频/混音、"
    "影响游戏行业且涉及音频的事件（如音频工作室收购/裁员/重组）。\n"
    "不相关：纯美术/网络/渲染/UI/gameplay 设计、与音频无关的商业新闻、"
    "通用音乐制作（非游戏向）、与游戏场景无关的音频技术。"
)


class RelevanceGate:
    def __init__(self, ai_client: AIClient, config: RelevanceGateConfig):
        self.client = ai_client
        self.threshold = config.threshold
        self.topic = config.topic or "game audio"

    def _build_prompt(self, item: ContentItem) -> str:
        title = (item.title or "").strip()
        body = (item.content or "")[:400].strip() if item.content else ""
        source = item.source_type.value if item.source_type else ""
        prompt = _PROMPT_TEMPLATE.format(
            topic=self.topic, title=title, summary=body, source=source
        )
        if "game audio" in self.topic.lower() or "游戏音" in self.topic:
            prompt += "\n\n" + _GAME_AUDIO_HINT
        return prompt

    async def _score_one(self, item: ContentItem) -> float:
        prompt = self._build_prompt(item)
        try:
            response = await self.client.complete(
                system="",
                user=prompt,
                max_tokens=10,
            )
        except Exception:
            # If scoring fails, be permissive — let the main analyzer judge.
            return 10.0
        match = re.search(r"\d+", response or "")
        if not match:
            return 10.0
        try:
            return float(match.group(0))
        except ValueError:
            return 10.0

    async def filter(self, items: List[ContentItem]) -> List[ContentItem]:
        if not items:
            return items
        scores = await asyncio.gather(
            *(self._score_one(item) for item in items),
            return_exceptions=False,
        )
        kept: List[ContentItem] = []
        for item, score in zip(items, scores):
            # Stash the score so it shows up in logs / debug dumps.
            setattr(item, "relevance_score", score)
            if score >= self.threshold:
                kept.append(item)
        return kept
