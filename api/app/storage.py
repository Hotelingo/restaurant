from __future__ import annotations

import asyncio
from functools import lru_cache

import boto3
from botocore.config import Config

from .config import Settings, get_settings


class StorageConfigurationError(RuntimeError):
    pass


class ObjectStorage:
    def __init__(self, settings: Settings):
        required = (
            settings.aws_endpoint_url_s3,
            settings.aws_region,
            settings.aws_access_key_id,
            settings.aws_secret_access_key,
        )
        if not all(required):
            raise StorageConfigurationError(
                "Object storage endpoint, region and scoped credentials are not configured."
            )

        self._client = boto3.client(
            "s3",
            region_name=settings.aws_region,
            endpoint_url=settings.aws_endpoint_url_s3,
            aws_access_key_id=settings.aws_access_key_id,
            aws_secret_access_key=settings.aws_secret_access_key,
            config=Config(
                s3={"addressing_style": "path"},
                request_checksum_calculation="when_required",
            ),
        )
        self.bucket = settings.storage_bucket

    async def put(
        self,
        *,
        key: str,
        data: bytes,
        content_type: str,
        sha256_hex: str,
    ) -> None:
        await asyncio.to_thread(
            self._client.put_object,
            Bucket=self.bucket,
            Key=key,
            Body=data,
            ContentType=content_type,
            Metadata={"sha256": sha256_hex},
        )

    async def delete(self, key: str) -> None:
        await asyncio.to_thread(
            self._client.delete_object,
            Bucket=self.bucket,
            Key=key,
        )

    async def presign_download(self, key: str, *, expires_seconds: int = 300) -> str:
        return await asyncio.to_thread(
            self._client.generate_presigned_url,
            "get_object",
            Params={"Bucket": self.bucket, "Key": key},
            ExpiresIn=expires_seconds,
        )


@lru_cache
def get_object_storage() -> ObjectStorage:
    return ObjectStorage(get_settings())
