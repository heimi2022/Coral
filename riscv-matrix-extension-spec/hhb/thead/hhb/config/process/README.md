<!--- Licensed to the Apache Software Foundation (ASF) under one -->
<!--- or more contributor license agreements.  See the NOTICE file -->
<!--- distributed with this work for additional information -->
<!--- regarding copyright ownership.  The ASF licenses this file -->
<!--- to you under the Apache License, Version 2.0 (the -->
<!--- "License"); you may not use this file except in compliance -->
<!--- with the License.  You may obtain a copy of the License at -->

<!---   http://www.apache.org/licenses/LICENSE-2.0 -->

<!--- Unless required by applicable law or agreed to in writing, -->
<!--- software distributed under the License is distributed on an -->
<!--- "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY -->
<!--- KIND, either express or implied.  See the License for the -->
<!--- specific language governing permissions and limitations -->
<!--- under the License. -->

## process lib

> process is a library that can read JPEG or PNG images and offers somes tools to transform image if neccessary.

### 1. Dependence

- [JPEG](https://www.ijg.org/)
- [libpng](http://www.libpng.org/pub/png/libpng.html)
- [zlib](https://zlib.net/)

### 2. Features provided

- `imread(const char *filename, struct image_data *img)`: read JPEG/PNG image and save the data and info of image to `img`
- `imresize(struct image_data *img, uint32_t dst_height, uint32_t dst_width)`: resize the image to target shape (dst_height, dst_width) by bilinear interpolation method
- `imsave(struct image_data img, const char *filename)`: save data to image
- `imrgb2bgr(struct image_data *img)`: convert image from RGB to BGR format
- `imhwc2chw(struct image_data *img)`: convert image data from HWC to CHW layout
- `im2rgb(struct image_data *img)`: Ensure that the number of channel of image data is 3. Note that if the channel the original image is 1, copy the single pixel 3 times to fill the RGB channel. If the channel the original image is 4, take the first three numbers.

### 3. How to use

```C
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "process.h"

int main() {
    char *filename = "cat.png";
    struct image_data img;
    imread(filename, &img);
    printf("height: %d, width: %d, channel: %d\n", img.shape[0],
            img.shape[1], img.shape[2]);

    save_data_to_file("cat_c.txt", img.data, get_size(img));
    return 0;
}
```

### 4. how to test

Firstly, download all the dependent libraries and put the folder in a directory at `process`'s level. For example, if the path of process is `/path/process`, the JPEG lib should be /path/jpeg, etc.

Then,
```Bash
cd tests
python3 test.py
```