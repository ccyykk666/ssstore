const status = document.querySelector('#status');
async function load() {
  try {
    const response = await fetch('./release.json', { cache: 'no-cache' });
    if (!response.ok) throw new Error('版本信息暂时不可用');
    const release = await response.json();
    const asset = new URL(release.downloadURL);
    if (asset.origin !== 'https://github.com' || !asset.pathname.startsWith('/ccyykk666/ssstore/releases/download/')) {
      throw new Error('下载地址无效');
    }
    const size = `${(release.bytes / 1024 / 1024).toFixed(1)} MiB`;
    document.querySelector('#version').textContent = `${release.version} (${release.build})`;
    document.querySelector('#size').textContent = size;
    document.querySelector('#date').textContent = release.builtAt.slice(0, 10);
    document.querySelector('#minimum-os').textContent = `iOS ${release.minimumOS} 及以上`;
    document.querySelector('#checksum').textContent = release.sha256;
    document.querySelector('#download').href = asset.href;
    document.querySelector('#build-link').href = release.buildURL;
    document.querySelector('#commit-link').textContent = release.commit.slice(0, 7);
    document.querySelector('#commit-link').href = `https://github.com/ccyykk666/ssstore/commit/${release.commit}`;
    status.textContent = `v${release.version} · ${size} · 构建 #${release.run}`;
  } catch (error) {
    status.textContent = '版本信息暂时不可用，仍可点击按钮下载最近发布的 IPA。';
    document.querySelector('#checksum').textContent = '请在 GitHub Releases 下载 SHA-256 校验文件。';
  }
}
load();
