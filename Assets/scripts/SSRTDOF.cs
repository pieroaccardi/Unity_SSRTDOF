/*
POSSIBILI OTTIMIZZAZIONI:

- Z-buffer gerarchico
- Approfondire il discorso reprojection
- Approfondire il discorso temporal sampling

 */

using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

public class SSRTDOF : MonoBehaviour
{
    //PUBLIC FIELDS
    public MeshRenderer[] meshes;
    public float FocalDistance = 5;
    public float Aperture = 0.01f;
    public float MarchingStep = 0.2f;

    //PRIVATE FIELDS
    private Camera cam;
    private Material mat;

    private RenderTexture depthBuffer;
    private RenderTexture rtBuffer;

    private Texture2D randomRotations;

    //PUBLIC METHODS

    //PRIVATE METHODS
    private void Awake()
    {
        cam = GetComponent<Camera>();

        //texture with linear depth
        depthBuffer = new RenderTexture(Screen.width, Screen.height, 24, RenderTextureFormat.RFloat, RenderTextureReadWrite.Linear);

        //render target for ray tracing pass
        rtBuffer = new RenderTexture(Screen.width / 2, Screen.height / 2, 0, RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB);

        //texture 16x16 for random samples rotations
        randomRotations = new Texture2D(16, 16, TextureFormat.RFloat, false, true);
        randomRotations.wrapMode = TextureWrapMode.Repeat;

        mat = new Material(Shader.Find("PostProcess/SSRTDOF"));

        CommandBuffer cb = new CommandBuffer();
        
        //fill the linear depth render target
        cb.SetRenderTarget(depthBuffer);
        cb.ClearRenderTarget(true, true, new Color(-float.MaxValue, -float.MaxValue, -float.MaxValue), 1.0f);
        
        foreach (MeshRenderer r in meshes)
            cb.DrawRenderer(r, mat, 0, 0);

        //random samples
        float[] samples = new float[64];
        for (int i = 0; i < 32; ++i)
        {
            Vector2 sample = Random.insideUnitCircle;
            samples[i * 2 + 0] = sample.x;
            samples[i * 2 + 1] = sample.y;
        }

        //random rotations
        Color[] rots = new Color[256];
        for (int i = 0; i < 256; ++i)
        {
            rots[i] = new Color(Random.Range(0, Mathf.PI * 2.0f), 0, 0, 0);
        }
        randomRotations.SetPixels(rots);
        randomRotations.Apply();

        //ray tracing pass
        mat.SetTexture("LinearDepthSampler", depthBuffer);
        mat.SetTexture("RandomRotations", randomRotations);
        mat.SetMatrix("frustumCorners", GetFrustumCorners(cam));
        mat.SetFloatArray("circleSamples", samples);
        mat.SetFloat("focalDistance", FocalDistance);
        mat.SetFloat("aperture", Aperture * 0.1f);
        mat.SetFloat("marchingStep", MarchingStep);

        mat.SetMatrix("ProjectionMat", GL.GetGPUProjectionMatrix(cam.projectionMatrix, false));

        cb.SetGlobalTexture("_MainTex", BuiltinRenderTextureType.CameraTarget);
        cb.Blit(BuiltinRenderTextureType.CameraTarget, rtBuffer, mat, 1);
        cb.Blit(rtBuffer, BuiltinRenderTextureType.CameraTarget);

        cam.AddCommandBuffer(CameraEvent.BeforeImageEffects, cb);
    }

    private void Update()
    {
        mat.SetFloat("focalDistance", FocalDistance);
        mat.SetFloat("aperture", Aperture * 0.1f);
        mat.SetFloat("marchingStep", MarchingStep);
        mat.SetFloat("W", Screen.width);
        mat.SetFloat("H", Screen.height);
    }

    private Matrix4x4 GetFrustumCorners(Camera cam)
    {
        float camFov = cam.fieldOfView;
        float camAspect = cam.aspect;

        Matrix4x4 frustumCorners = Matrix4x4.identity;

        float fovWHalf = camFov * 0.5f;

        float tan_fov = Mathf.Tan(fovWHalf * Mathf.Deg2Rad);

        Vector3 toRight = Vector3.right * tan_fov * camAspect;
        Vector3 toTop = Vector3.up * tan_fov;

        Vector3 topLeft = (-Vector3.forward - toRight + toTop);
        Vector3 topRight = (-Vector3.forward + toRight + toTop);
        Vector3 bottomRight = (-Vector3.forward + toRight - toTop);
        Vector3 bottomLeft = (-Vector3.forward - toRight - toTop);

        frustumCorners.SetRow(0, bottomLeft);
        frustumCorners.SetRow(1, topLeft);
        frustumCorners.SetRow(2, topRight);
        frustumCorners.SetRow(3, bottomRight);
        
        return frustumCorners;
    }
}
