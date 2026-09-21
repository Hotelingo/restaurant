-- 0013 · Source-file safety metadata
-- Every persisted raw upload must have passed deterministic content inspection
-- and a malware scan. The R1 bucket is private "uploads".

alter table source_file
  add column detected_file_type text,
  add column row_count integer,
  add column malware_scan_status text,
  add column malware_scanner text,
  add column malware_scanned_at timestamptz,
  add column inspection_json jsonb not null default '{}'::jsonb;

alter table source_file
  add constraint source_file_storage_bucket_check
    check (storage_bucket = 'uploads'),
  add constraint source_file_content_type_check
    check (
      content_type in (
        'text/csv',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
      )
    ),
  add constraint source_file_detected_file_type_check
    check (detected_file_type in ('csv','xlsx')),
  add constraint source_file_size_cap_check
    check (size_bytes > 0 and size_bytes <= 26214400),
  add constraint source_file_row_cap_check
    check (row_count > 0 and row_count <= 250000),
  add constraint source_file_malware_clean_check
    check (malware_scan_status = 'clean'),
  add constraint source_file_malware_scanner_check
    check (length(btrim(malware_scanner)) > 0),
  add constraint source_file_inspection_object_check
    check (jsonb_typeof(inspection_json) = 'object');

alter table source_file
  alter column content_type set not null,
  alter column detected_file_type set not null,
  alter column row_count set not null,
  alter column malware_scan_status set not null,
  alter column malware_scanner set not null,
  alter column malware_scanned_at set not null;

-- Forward-fix only after customer uploads exist. The safety metadata is part of
-- source lineage and must not be dropped or backfilled with invented values.
