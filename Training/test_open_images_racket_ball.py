import csv
import json
import tempfile
import unittest
from pathlib import Path

import prepare_open_images_racket_ball as prepare


class OpenImagesRacketBallTests(unittest.TestCase):
    def test_collects_only_explicit_tennis_classes_and_valid_boxes(self):
        rows = [
            self.box("a", "/m/05ctyq", "0.1", "0.2", "0.3", "0.5"),
            self.box("a", "/m/0h8my_4", "0.4", "0.8", "0.1", "0.9"),
            self.box("b", "/m/0dv9c", "0.1", "0.2", "0.3", "0.5"),
            self.box("c", "/m/05ctyq", "0.3", "0.2", "0.3", "0.5"),
        ]

        result = prepare.collect_boxes(rows)

        self.assertEqual(set(result), {"a"})
        self.assertEqual([item["label"] for item in result["a"]], [
            "tennis_ball", "tennis_racket",
        ])

    def test_metadata_fails_closed_without_explicit_attribution_license(self):
        rows = [
            self.metadata("a", "https://creativecommons.org/licenses/by/2.0/"),
            self.metadata("b", "https://creativecommons.org/licenses/by-nc/4.0/"),
        ]

        accepted, rejected = prepare.collect_licensed_metadata(rows, {"a", "b", "c"})

        self.assertEqual(set(accepted), {"a"})
        self.assertEqual(accepted["a"]["downloadURLs"], [
            "https://example.com/thumb.jpg",
            "https://example.com/original.jpg",
        ])
        self.assertEqual(rejected["licenseNotExplicitlyAllowed"], 1)
        self.assertEqual(rejected["missingMetadata"], 1)

    def test_prepare_writes_attribution_bound_records_without_downloading(self):
        with tempfile.TemporaryDirectory(prefix="serveai-open-images-test-") as temporary:
            root = Path(temporary)
            boxes = root / "boxes.csv"
            metadata = root / "metadata.csv"
            output = root / "output"
            self.write_csv(boxes, [
                self.box("a", "/m/05ctyq", "0.1", "0.2", "0.3", "0.5"),
            ])
            self.write_csv(metadata, [
                self.metadata("a", "https://creativecommons.org/licenses/by/2.0/"),
            ])

            summary = prepare.prepare(
                split="validation",
                boxes_source=str(boxes),
                metadata_source=str(metadata),
                output=output,
                download=False,
                max_images=None,
            )

            self.assertEqual(summary["writtenImageCount"], 1)
            self.assertFalse(summary["releaseInterpretation"]["canEstablishServeTechniqueAccuracy"])
            record = json.loads((output / "annotations.jsonl").read_text().strip())
            self.assertEqual(record["attribution"]["author"], "A Photographer")
            self.assertEqual(record["boxes"][0]["label"], "tennis_ball")

    def test_create_ml_annotations_convert_normalized_corners_to_pixel_centers(self):
        records = [{
            "localImage": "images/a.jpg",
            "pixelWidth": 1000,
            "pixelHeight": 500,
            "boxes": [{
                "label": "tennis_racket",
                "xmin": 0.10,
                "xmax": 0.50,
                "ymin": 0.20,
                "ymax": 0.60,
            }],
        }]

        result = prepare.create_ml_annotations(records)

        self.assertEqual(result[0]["image"], "a.jpg")
        coordinates = result[0]["annotations"][0]["coordinates"]
        for key, expected in {
            "x": 300,
            "y": 200,
            "width": 400,
            "height": 200,
        }.items():
            self.assertAlmostEqual(coordinates[key], expected)

    @staticmethod
    def box(image_id, label, xmin, xmax, ymin, ymax):
        return {
            "ImageID": image_id,
            "LabelName": label,
            "XMin": xmin,
            "XMax": xmax,
            "YMin": ymin,
            "YMax": ymax,
            "IsOccluded": "0",
            "IsTruncated": "0",
            "IsGroupOf": "0",
            "IsDepiction": "0",
        }

    @staticmethod
    def metadata(image_id, license_url):
        return {
            "ImageID": image_id,
            "License": license_url,
            "Author": "A Photographer",
            "AuthorProfileURL": "https://example.com/author",
            "Title": "Tennis",
            "OriginalURL": "https://example.com/original.jpg",
            "OriginalLandingURL": "https://example.com/photo",
            "Thumbnail300KURL": "https://example.com/thumb.jpg",
            "Rotation": "0",
        }

    @staticmethod
    def write_csv(path, rows):
        with path.open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=rows[0].keys())
            writer.writeheader()
            writer.writerows(rows)


if __name__ == "__main__":
    unittest.main()
