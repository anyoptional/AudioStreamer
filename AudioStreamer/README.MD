


CFNetwork + AudioFile + AudioConverter + AudioUnit组合的经典音频播放流程（以MP3为例）：

1、读取MP3文件
2、解析采样率、码率、时长等信息，分离MP3中的音频帧
3、对分离出来的音频帧解码得到PCM数据
4、把PCM数据解码成音频信号并交给硬件播放
5、重复1-4步直到播放完成

Note：如果需要混音、均衡器等，在第3步和第4步之间进行。
