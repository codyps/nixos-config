"""Offline regression tests against the installed, real delta-request function.

All LLM responses below are synthetic fixtures; no network/API calls are made.
Only the LLM boundary is substituted. Parsing, validation, reference checking,
repair prompt creation and operation application are the installed implementation.
"""
from __future__ import annotations

import asyncio
import copy
import json
import unittest

import httpx
from openai import AsyncOpenAI
from hindsight_api.engine.providers.openai_compatible_llm import OpenAICompatibleLLM

from hindsight_api.engine.reflect.delta_ops import (
    DeltaOperationList,
    apply_operations,
    request_delta_operations,
)
from hindsight_api.engine.reflect.structured_doc import Block, Section, StructuredDocument
from hindsight_api.engine.response_models import LLMCallResult


class FixtureLLM:
    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls = []

    async def call(self, *, messages, **kwargs):
        self.calls.append((copy.deepcopy(messages), dict(kwargs)))
        return LLMCallResult(content=self.responses.pop(0))


def baseline():
    return StructuredDocument(sections=[Section(
        id="known", heading="Known", blocks=[Block(id="b1", text="Keep this unchanged.")]
    )])


class DeltaRepairRegression(unittest.IsolatedAsyncioTestCase):
    async def test_structured_missing_reference_repair_echoes_json_text(self):
        """Reproduce messages[2].content being an object after skip_validation."""
        original = baseline()
        before = original.model_dump()
        bad = {"operations": [
            {"op": "append_block", "section_id": "known", "text": "New evidence: café 東京"},
            {"op": "replace_block", "section_id": "known", "block_id": "mistyped", "text": "Correct me"},
        ]}
        good = {"operations": [
            bad["operations"][0],
            {"op": "replace_block", "section_id": "known", "block_id": "b1", "text": "Correct me"},
        ]}
        llm = FixtureLLM(bad, good)
        kwargs = dict(response_format=DeltaOperationList, skip_validation=True,
                      strict_schema=False, max_completion_tokens=4096, temperature=0)
        result = await request_delta_operations(
            llm, system_prompt="Synthetic system prefix", user_prompt="Synthetic document prefix",
            scope="mental_model_delta_ops", document=original, **kwargs,
        )
        self.assertEqual(len(llm.calls), 2)
        first_messages, first_kwargs = llm.calls[0]
        retry_messages, retry_kwargs = llm.calls[1]
        self.assertEqual(retry_messages[:2], first_messages)
        self.assertEqual(first_kwargs, dict(scope="mental_model_delta_ops", **kwargs))
        self.assertEqual(retry_kwargs, first_kwargs)
        self.assertEqual(retry_messages[2]["role"], "assistant")
        self.assertIsInstance(retry_messages[2]["content"], str,
                              "messages[2].content must be JSON text, not parsed structured output")
        self.assertEqual(json.loads(retry_messages[2]["content"]), bad)
        self.assertIn("mistyped", retry_messages[3]["content"])
        self.assertIn("b1", retry_messages[3]["content"])
        self.assertTrue(all(isinstance(m["content"], str) for m in retry_messages))
        self.assertEqual(original.model_dump(), before, "repair must not mutate the document")
        self.assertEqual(result.model_dump(), DeltaOperationList.model_validate(good).model_dump())
        applied = apply_operations(original, result.operations)
        self.assertEqual(len(applied.applied), 2)
        self.assertEqual(applied.skipped, [])
    async def test_validated_model_missing_reference_repair_echoes_json_text(self):
        bad = DeltaOperationList.model_validate({"operations": [
            {"op": "append_block", "section_id": "mistyped", "text": "Preserve café 東京"}
        ]})
        good = {"operations": [
            {"op": "append_block", "section_id": "known", "text": "Preserve café 東京"}
        ]}
        llm = FixtureLLM(bad, DeltaOperationList.model_validate(good))
        result = await request_delta_operations(
            llm, system_prompt="System", user_prompt="Document", scope="mental_model_delta_ops",
            document=baseline(), response_format=DeltaOperationList, skip_validation=False,
        )
        echo = llm.calls[1][0][2]["content"]
        self.assertIsInstance(echo, str, "validated provider models must also be echoed as JSON text")
        self.assertEqual(json.loads(echo), bad.model_dump(mode="json"))
        self.assertEqual(result.model_dump(), DeltaOperationList.model_validate(good).model_dump())
    async def test_schema_repair_keeps_unknown_fields_in_echo_but_rejects_them(self):
        bad = {"operations": [
            {"op": "append_block", "section_id": "known", "text": "Valid part"},
            {"op": "append_block", "section_id": "known", "text": "Invalid part", "invented": None},
        ]}
        good = {"operations": [{"op": "append_block", "section_id": "known", "text": "Complete correction"}]}
        llm = FixtureLLM(bad, good)
        with self.assertLogs("hindsight_api.engine.reflect.delta_ops", level="WARNING"):
            result = await request_delta_operations(
                llm, system_prompt="System", user_prompt="Document", scope="mental_model_delta_ops",
                response_format=DeltaOperationList, skip_validation=True,
            )
        retry = llm.calls[1][0]
        self.assertEqual(json.loads(retry[2]["content"]), bad)
        self.assertIn("invented", retry[3]["content"])
        self.assertIn("nothing you sent has been applied", retry[3]["content"])
        self.assertEqual(len(result.operations), 1)
        self.assertEqual(result.operations[0].text, "Complete correction")

    async def test_text_mode_retraction_repair_preserves_original_bytes(self):
        bad = '  ```json\n{"operations":[{"op":"append_block","section_id":"known","text":"café 東京","invented":null}]}\n```  '
        llm = FixtureLLM(bad, '{"operations":[]}')
        with self.assertLogs("hindsight_api.engine.reflect.delta_ops", level="WARNING"):
            result = await request_delta_operations(
                llm, system_prompt="System", user_prompt="Document", scope="mental_model_retraction_ops",
            )
        self.assertEqual(llm.calls[1][0][2]["content"], bad)
        self.assertEqual(llm.calls[1][1]["scope"], "mental_model_retraction_ops")
        self.assertEqual(result.operations, [])

    async def test_second_invalid_reply_fails_without_partial_apply_or_third_call(self):
        from hindsight_api.engine.reflect.delta_ops import DeltaOperationsInvalidError
        original = baseline()
        before = original.model_dump()
        bad = {"operations": [
            {"op": "append_block", "section_id": "known", "text": "Do not apply partial edit"},
            {"op": "append_block", "section_id": "known", "text": "Bad", "invented": 1},
        ]}
        llm = FixtureLLM(bad, bad)
        with self.assertLogs("hindsight_api.engine.reflect.delta_ops", level="WARNING"):
            with self.assertRaises(DeltaOperationsInvalidError):
                await request_delta_operations(
                    llm, system_prompt="System", user_prompt="Document", scope="mental_model_delta_ops",
                    document=original, response_format=DeltaOperationList, skip_validation=True,
                )
        self.assertEqual(len(llm.calls), 2)
        self.assertEqual(original.model_dump(), before)

    async def test_valid_first_reply_needs_no_repair(self):
        good = {"operations": [{"op": "append_block", "section_id": "known", "text": "Valid"}]}
        llm = FixtureLLM(good)
        result = await request_delta_operations(
            llm, system_prompt="System", user_prompt="Document", scope="mental_model_delta_ops",
            document=baseline(), response_format=DeltaOperationList, skip_validation=True,
        )
        self.assertEqual(len(llm.calls), 1)
        self.assertEqual(result.operations[0].text, "Valid")
    async def test_deepseek_sdk_serializes_repair_over_offline_http_transport(self):
        """Real provider + real OpenAI SDK; synthetic HTTP transport, never the API."""
        requests = []
        bad = {"operations": [
            {"op": "replace_block", "section_id": "known", "block_id": "mistyped", "text": "café 東京"}
        ]}
        good = {"operations": [
            {"op": "replace_block", "section_id": "known", "block_id": "b1", "text": "café 東京"}
        ]}

        def fixture_response(request):
            body = json.loads(request.content)
            requests.append(body)
            if any(not isinstance(m["content"], str) for m in body["messages"]):
                return httpx.Response(422, json={"error": {
                    "message": "Synthetic contract check: messages[2]: content should be a string or a list",
                    "type": "invalid_request_error",
                }})
            payload = bad if len(requests) == 1 else good
            return httpx.Response(200, json={
                "id": "synthetic-offline-fixture", "object": "chat.completion", "created": 0,
                "model": "deepseek-flash", "choices": [{"index": 0, "finish_reason": "stop",
                    "message": {"role": "assistant", "content": json.dumps(payload, ensure_ascii=False)}}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
            })

        provider = await asyncio.to_thread(
            OpenAICompatibleLLM,
            provider="deepseek", model="deepseek-flash", api_key="synthetic-not-a-real-key",
            base_url="https://offline.invalid/v1", extra_body={"thinking": {"type": "disabled"}},
        )
        await provider._client.close()
        provider._client = await asyncio.to_thread(
            AsyncOpenAI,
            api_key="synthetic-not-a-real-key", base_url="https://offline.invalid/v1", max_retries=0,
            http_client=httpx.AsyncClient(transport=httpx.MockTransport(fixture_response)),
        )
        try:
            with self.assertLogs("hindsight_api.engine.reflect.delta_ops", level="WARNING"):
                result = await request_delta_operations(
                    provider, system_prompt="json system", user_prompt="json document",
                    scope="mental_model_delta_ops", document=baseline(), response_format=DeltaOperationList,
                    skip_validation=True, strict_schema=False, max_retries=0,
                )
        finally:
            await provider._client.close()
        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[1]["messages"][:2], requests[0]["messages"])
        self.assertEqual(json.loads(requests[1]["messages"][2]["content"]), bad)
        self.assertEqual(requests[1]["thinking"], {"type": "disabled"})
        self.assertEqual(result.model_dump(), DeltaOperationList.model_validate(good).model_dump())


if __name__ == "__main__":
    unittest.main(verbosity=2)
